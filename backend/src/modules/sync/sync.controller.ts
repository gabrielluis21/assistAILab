import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import {
  EquipmentOwnerType,
  ServiceOrderStatus,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  pushSyncSchema,
  pullSyncQuerySchema,
} from './sync.schema.js';

import {
  computePayloadHash,
} from '../../core/middleware/idempotency.middleware.js';

import {
  isValidStatusTransition,
} from '../service_orders/service_order_state_machine.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';
import {
  recordServiceOrderSyncChange,
} from '../../core/sync/sync_change_log.service.js';
import {
  getAuthUser,
} from '../../core/middleware/auth.middleware.js';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

/**
 * Reserva atomicamente uma chave de idempotência.
 */
async function reserveIdempotencySlot(
  operationId: string,
  currentHash: string,
  userId: string,
  deviceId?: string
): Promise<
  | {
    isNew: true;
  }
  | {
    isNew: false;
    conflict: boolean;
    responseBody?: unknown;
    responseStatus?: number;
    createdAt?: Date;
  }
> {
  try {
    await prisma.operationIdempotency.create({
      data: {
        operationId,

        endpoint:
          '/api/v1/sync/push',

        requestHash:
          currentHash,

        responseStatus:
          102,

        responseBody: {
          status:
            'PROCESSING',
        },

        status:
          'PROCESSING',

        processingExpiresAt:
          new Date(
            Date.now() +
            5 * 60 * 1000
          ),

        userId,

        deviceId:
          deviceId ?? null,
      },
    });

    return {
      isNew: true,
    };
  } catch (err: any) {
    if (
      err?.code ===
      'P2002'
    ) {
      const existing =
        await prisma.operationIdempotency.findUnique({
          where: {
            operationId,
          },
        });

      if (!existing) {
        return {
          isNew: true,
        };
      }

      if (
        existing.requestHash !==
        currentHash
      ) {
        return {
          isNew: false,
          conflict: true,
        };
      }

      const responseBody =
        existing.responseBody as
        {
          status?: string;
        } | null;

      const ageMs =
        Date.now() -
        existing.createdAt.getTime();

      const recoverableProcessing =
        existing.responseStatus ===
        102 &&
        ageMs >
        5 * 60 * 1000;

      const legacyIncomplete =
        existing.responseStatus ===
        200 &&
        responseBody?.status !==
        'SYNCED' &&
        ageMs >
        5 * 60 * 1000;

      if (
        recoverableProcessing ||
        legacyIncomplete
      ) {
        await prisma.operationIdempotency.deleteMany({
          where: {
            operationId,

            requestHash:
              currentHash,
          },
        });

        return reserveIdempotencySlot(
          operationId,
          currentHash,
          userId,
          deviceId
        );
      }

      return {
        isNew: false,
        conflict: false,

        responseBody:
          existing.responseBody,

        responseStatus:
          existing.responseStatus ??
          undefined,

        createdAt:
          existing.createdAt,
      };
    }

    throw err;
  }
}
/**
 * Obtém a organização associada
 * ao usuário autenticado.
 *
 * ADMIN / TECHNICIAN:
 * organização vem da Membership.
 *
 * CUSTOMER:
 * organização vem da relação
 * CustomerOrganization ativa.
 *
 * O client nunca fornece organizationId
 * como fonte de autoridade.
 */
async function getAuthenticatedOrganizationId(
  userId: string,
  role: string,
  customerId: string | null
): Promise<string> {
  if (
    role ===
    'CUSTOMER'
  ) {
    if (!customerId) {
      throw new ForbiddenError(
        'CUSTOMER user has no associated Customer identity'
      );
    }

    const customerOrganization =
      await prisma.customerOrganization.findFirst({
        where: {
          customerId,
          status:
            'ACTIVE',
        },

        orderBy: {
          createdAt:
            'asc',
        },

        select: {
          organizationId:
            true,
        },
      });

    if (
      !customerOrganization
    ) {
      throw new ForbiddenError(
        'Customer is not associated with an active organization'
      );
    }

    return (
      customerOrganization.organizationId
    );
  }

  const membership =
    await prisma.membership.findFirst({
      where: {
        userId,
      },

      orderBy: {
        createdAt:
          'asc',
      },

      select: {
        organizationId:
          true,
      },
    });

  if (!membership) {
    throw new ForbiddenError(
      'User is not associated with an organization'
    );
  }

  return membership.organizationId;
}

/**
 * Valida se uma entidade existente
 * pode ser acessada pela organização.
 *
 * IMPORTANTE:
 *
 * Equipment possui duas regras:
 *
 * CUSTOMER:
 *   a organização somente acessa
 *   através de uma ServiceOrder.
 *
 * ORGANIZATION:
 *   a organização proprietária possui
 *   acesso direto.
 */
async function validateOrganizationOwnership(
  entityType: string,
  entityId: string,
  organizationId: string
): Promise<void> {
  const entityUpper =
    entityType.toUpperCase();

  /**
   * CUSTOMER
   */
  if (
    entityUpper ===
    'CUSTOMER'
  ) {
    /**
     * Permite CREATE de um novo Customer.
     */
    const customer =
      await prisma.customer.findUnique({
        where: {
          id:
            entityId,
        },

        select: {
          id:
            true,

          organizations: {
            where: {
              organizationId,
            },

            select: {
              id:
                true,
            },
          },
        },
      });

    if (!customer) {
      return;
    }

    if (
      customer.organizations.length ===
      0
    ) {
      throw new ForbiddenError(
        'Customer does not belong to the authenticated organization'
      );
    }

    return;
  }

  /**
   * EQUIPMENT
   */
  if (
    entityUpper ===
    'EQUIPMENT'
  ) {
    const equipment =
      await prisma.equipment.findUnique({
        where: {
          id:
            entityId,
        },

        select: {
          id:
            true,

          customerId:
            true,

          organizationId:
            true,

          ownerType:
            true,
        },
      });

    /**
     * O equipamento ainda não existe.
     *
     * CREATE será validado posteriormente
     * dentro da transação.
     */
    if (!equipment) {
      return;
    }

    /**
     * Equipamento pertencente
     * à própria organização.
     */
    if (
      equipment.ownerType ===
      EquipmentOwnerType.ORGANIZATION
    ) {
      if (
        !equipment.organizationId ||
        equipment.organizationId !==
        organizationId
      ) {
        throw new ForbiddenError(
          'Equipment does not belong to the authenticated organization'
        );
      }

      return;
    }

    /**
     * Equipment CUSTOMER deveria
     * possuir customerId.
     *
     * Se não possuir, o estado do registro
     * é inconsistente.
     */
    if (
      !equipment.customerId
    ) {
      throw new ForbiddenError(
        'Customer-owned equipment has no associated customer'
      );
    }

    /**
     * CustomerOrganization NÃO concede
     * automaticamente acesso aos equipamentos.
     *
     * A organização só conhece o equipamento
     * dentro do contexto de uma OS.
     */
    const serviceOrder =
      await prisma.serviceOrder.findFirst({
        where: {
          equipmentId:
            equipment.id,

          organizationId,
        },

        select: {
          id:
            true,
        },
      });

    if (!serviceOrder) {
      throw new ForbiddenError(
        'Organization has no Service Order granting access to this equipment'
      );
    }

    return;
  }

  /**
   * SERVICE ORDER
   */
  if (
    entityUpper ===
    'SERVICE_ORDER'
  ) {
    const order =
      await prisma.serviceOrder.findUnique({
        where: {
          id:
            entityId,
        },

        select: {
          organizationId:
            true,
        },
      });

    if (
      order &&
      order.organizationId !==
      organizationId
    ) {
      throw new ForbiddenError(
        'Service Order does not belong to the authenticated organization'
      );
    }

    return;
  }

  /**
   * SERVICE ORDER ITEM
   */
  if (
    entityUpper ===
    'SERVICE_ORDER_ITEM'
  ) {
    const item =
      await prisma.serviceOrderItem.findUnique({
        where: {
          id:
            entityId,
        },

        select: {
          serviceOrder: {
            select: {
              organizationId:
                true,
            },
          },
        },
      });

    if (
      item &&
      item.serviceOrder
        .organizationId !==
      organizationId
    ) {
      throw new ForbiddenError(
        'Service Order Item does not belong to the authenticated organization'
      );
    }

    return;
  }

  /**
   * PAYMENT
   */
  if (
    entityUpper ===
    'PAYMENT'
  ) {
    const payment =
      await prisma.payment.findUnique({
        where: {
          id:
            entityId,
        },

        select: {
          organizationId:
            true,
        },
      });

    if (
      payment &&
      payment.organizationId !==
      organizationId
    ) {
      throw new ForbiddenError(
        'Payment does not belong to the authenticated organization'
      );
    }

    return;
  }

  /**
   * PART
   *
   * Atualmente Part ainda é global.
   */
  if (
    entityUpper ===
    'PART'
  ) {
    return;
  }

  throw new ForbiddenError(
    `Unsupported entity type: ${entityType}`
  );
}

/**
 * Garante que o Sync genérico de Equipment
 * não seja utilizado para transferir propriedade.
 *
 * Transferência:
 *
 * CUSTOMER
 *     ↓
 * ORGANIZATION
 *
 * deverá ocorrer exclusivamente através
 * do EquipmentAcquisitionService.
 */
export function assertGenericEquipmentSyncPayload(
  payload: Record<string, any>
): void {
  const requestedOwnerType =
    payload.owner_type ??
    payload.ownerType;

  const requestedOrganizationId =
    payload.organization_id ??
    payload.organizationId;

  const requestedPurpose =
    payload.organization_purpose ??
    payload.organizationPurpose;

  /**
   * O Sync genérico só representa
   * Equipment pertencente ao Customer.
   */
  if (
    requestedOwnerType &&
    requestedOwnerType !==
    EquipmentOwnerType.CUSTOMER
  ) {
    throw new ForbiddenError(
      'Equipment ownership cannot be transferred through generic Sync'
    );
  }

  /**
   * organizationId também não pode
   * ser injetado pelo client.
   */
  if (
    requestedOrganizationId
  ) {
    throw new ForbiddenError(
      'organizationId cannot be assigned to Equipment through generic Sync'
    );
  }

  /**
   * Finalidade organizacional só existe
   * depois de uma aquisição válida.
   */
  if (
    requestedPurpose
  ) {
    throw new ForbiddenError(
      'organizationPurpose cannot be assigned through generic Sync'
    );
  }
}

/**
 * Valida que CUSTOMER manipula somente
 * entidades relacionadas à própria identidade.
 */
async function validateCustomerOwnership(
  entityType: string,
  entityId: string,
  payload: Record<string, any>,
  authenticatedCustomerId: string
): Promise<void> {
  const entityUpper =
    entityType.toUpperCase();

  /**
   * CUSTOMER
   */
  if (
    entityUpper ===
    'CUSTOMER'
  ) {
    if (
      entityId !==
      authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer'
      );
    }

    return;
  }

  /**
   * EQUIPMENT
   */
  if (
    entityUpper ===
    'EQUIPMENT'
  ) {
    assertGenericEquipmentSyncPayload(
      payload
    );

    const equipment =
      await prisma.equipment.findUnique({
        where: {
          id:
            entityId,
        },

        select: {
          customerId:
            true,

          ownerType:
            true,

          organizationId:
            true,
        },
      });

    /**
     * Se já existe, obrigatoriamente
     * deve continuar sendo do Customer.
     */
    if (equipment) {
      if (
        equipment.ownerType !==
        EquipmentOwnerType.CUSTOMER
      ) {
        throw new ForbiddenError(
          'CUSTOMER cannot modify organization-owned equipment'
        );
      }

      if (
        equipment.customerId !==
        authenticatedCustomerId
      ) {
        throw new ForbiddenError(
          'CUSTOMER cannot modify another Customer equipment'
        );
      }
    }

    const payloadCustomerId =
      payload.customer_id ??
      payload.customerId;

    if (
      payloadCustomerId &&
      payloadCustomerId !==
      authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot assign Equipment to another Customer'
      );
    }

    return;
  }

  /**
   * SERVICE ORDER
   */
  if (
    entityUpper ===
    'SERVICE_ORDER'
  ) {
    const serviceOrder =
      await prisma.serviceOrder.findUnique({
        where: {
          id:
            entityId,
        },
      });

    if (
      serviceOrder &&
      serviceOrder.customerId !==
      authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer Service Order'
      );
    }

    const payloadCustomerId =
      payload.customer_id ??
      payload.customerId;

    if (
      payloadCustomerId &&
      payloadCustomerId !==
      authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot assign Service Order to another Customer'
      );
    }

    return;
  }

  /**
   * SERVICE ORDER ITEM
   */
  if (
    entityUpper ===
    'SERVICE_ORDER_ITEM'
  ) {
    const item =
      await prisma.serviceOrderItem.findUnique({
        where: {
          id:
            entityId,
        },

        include: {
          serviceOrder: {
            select: {
              customerId:
                true,
            },
          },
        },
      });

    if (
      item &&
      item.serviceOrder
        .customerId !==
      authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer Service Order Item'
      );
    }

    return;
  }

  /**
   * PAYMENT
   */
  if (
    entityUpper ===
    'PAYMENT'
  ) {
    const payment =
      await prisma.payment.findUnique({
        where: {
          id:
            entityId,
        },
      });

    if (
      payment &&
      payment.customerId !==
      authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer Payment'
      );
    }

    return;
  }

  /**
   * CUSTOMER não manipula Parts
   * ou outros tipos arbitrários.
   */
  throw new ForbiddenError(
    `CUSTOMER cannot modify entity type ${entityType}`
  );
}

/**
 * PUSH SYNC
 */
export async function pushSyncHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body =
    pushSyncSchema.parse(
      request.body
    );

  const authUser =
    getAuthUser(
      request
    );

  const authenticatedUserId =
    authUser.sub;

  let defaultOrganizationId:
    string;
  try {
    defaultOrganizationId =
      await getAuthenticatedOrganizationId(
        authenticatedUserId,
        authUser.role,
        authUser.customerId
      );
  } catch (error) {
    if (
      error instanceof
      ForbiddenError
    ) {
      return reply
        .status(403)
        .send({
          error:
            error.message,
        });
    }

    throw error;
  }

  const results: Array<{
    operationId: string;
    status:
    | 'SYNCED'
    | 'FAILED'
    | 'CONFLICT';
    error?: string;
  }> = [];

  for (
    const entry of
    body.entries
  ) {
    try {
      const currentHash =
        computePayloadHash(
          entry.payload
        );

      const entityUpper =
        entry.entityType
          .toUpperCase();

      /**
       * FIN_F01_GENERIC_PAYMENT_PUSH_BLOCK
       *
       * Payment mutations are Finance authority writes and
       * must use the hardened REST command surface.
       * Sync remains Pull-compatible only for Payment.
       */
      if (
        entityUpper ===
        'PAYMENT'
      ) {
        results.push({
          operationId:
            entry.operationId,
          status:
            'FAILED',
          error:
            'PAYMENT_GENERIC_SYNC_WRITE_BLOCKED',
        });

        continue;
      }

      let organizationId =
        defaultOrganizationId;

      /**
       * CLIENT_GATE_CUSTOMER_RESOURCE_TENANT
       *
       * CUSTOMER é global. Para ServiceOrder já
       * existente, o tenant vem do próprio recurso
       * pertencente ao Customer autenticado.
       */
      if (
        authUser.role ===
        'CUSTOMER' &&
        entityUpper ===
        'SERVICE_ORDER' &&
        authUser.customerId
      ) {
        const targetServiceOrder =
          await prisma.serviceOrder.findFirst({
            where: {
              id:
                entry.entityId,

              customerId:
                authUser.customerId,
            },

            select: {
              organizationId:
                true,
            },
          });

        if (
          targetServiceOrder
        ) {
          organizationId =
            targetServiceOrder.organizationId;
        }
      }

      /**
       * Organization boundary.
       *
       * Exceção:
       *
       * CUSTOMER pode manipular seu próprio
       * Equipment antes da primeira OS.
       *
       * Nesse caso a autoridade vem da
       * identidade CUSTOMER, não da Organization.
       */
      const skipOrganizationEquipmentCheck =
        authUser.role ===
        'CUSTOMER' &&
        entityUpper ===
        'EQUIPMENT';

      if (
        !skipOrganizationEquipmentCheck
      ) {
        await validateOrganizationOwnership(
          entry.entityType,
          entry.entityId,
          organizationId
        );
      }

      /**
       * CUSTOMER boundary.
       */
      if (
        authUser.role ===
        'CUSTOMER'
      ) {
        if (
          !authUser.customerId
        ) {
          results.push({
            operationId:
              entry.operationId,

            status:
              'FAILED',

            error:
              'CUSTOMER user has no associated Customer identity',
          });

          continue;
        }

        await validateCustomerOwnership(
          entry.entityType,
          entry.entityId,
          entry.payload,
          authUser.customerId
        );
      }

      /**
       * Idempotency.
       */
      const idempotencyResult =
        await reserveIdempotencySlot(
          entry.operationId,
          currentHash,
          authenticatedUserId,
          entry.deviceId
        );

      if (
        !idempotencyResult.isNew
      ) {
        if (
          idempotencyResult.conflict
        ) {
          results.push({
            operationId:
              entry.operationId,

            status:
              'CONFLICT',

            error:
              'IDEMPOTENCY_KEY_REUSE: Operation ID was reused with a different payload',
          });

          continue;
        }

        const existingResponse =
          idempotencyResult
            .responseBody as
          {
            status?: string;
          } | undefined;

        if (
          idempotencyResult
            .responseStatus ===
          200 &&
          existingResponse
            ?.status ===
          'SYNCED'
        ) {
          results.push({
            operationId:
              entry.operationId,

            status:
              'SYNCED',
          });

          continue;
        }

        results.push({
          operationId:
            entry.operationId,

          status:
            'FAILED',

          error:
            'IDEMPOTENCY_OPERATION_IN_PROGRESS',
        });

        continue;
      }
      /**
       * Processamento atômico.
       */
      await prisma.$transaction(
        async (tx) => {
          /**
           * CUSTOMER
           */
          if (
            entityUpper ===
            'CUSTOMER'
          ) {
            if (
              entry.operationType ===
              'CREATE' ||
              entry.operationType ===
              'UPDATE'
            ) {
              await tx.customer.upsert({
                where: {
                  id:
                    entry.entityId,
                },

                create: {
                  id:
                    entry.entityId,

                  name:
                    entry.payload.name,

                  document:
                    entry.payload.document ??
                    null,

                  email:
                    entry.payload.email ??
                    null,

                  phone:
                    entry.payload.phone ??
                    null,

                  address:
                    entry.payload.address ??
                    null,
                },

                update: {
                  name:
                    entry.payload.name,

                  document:
                    entry.payload.document ??
                    null,

                  email:
                    entry.payload.email ??
                    null,

                  phone:
                    entry.payload.phone ??
                    null,

                  address:
                    entry.payload.address ??
                    null,
                },
              });

              /**
               * Relaciona Customer
               * à Organization atual.
               */
              await tx.customerOrganization.upsert({
                where: {
                  customerId_organizationId: {
                    customerId:
                      entry.entityId,

                    organizationId,
                  },
                },

                create: {
                  customerId:
                    entry.entityId,

                  organizationId,

                  status:
                    'ACTIVE',
                },

                update: {},
              });
            } else if (
              entry.operationType ===
              'DELETE'
            ) {
              /**
               * Não remove identidade global.
               *
               * Remove apenas o relacionamento
               * com a Organization atual.
               */
              await tx.customerOrganization
                .delete({
                  where: {
                    customerId_organizationId: {
                      customerId:
                        entry.entityId,

                      organizationId,
                    },
                  },
                })
                .catch(
                  () =>
                    null
                );
            }
          }

          /**
           * EQUIPMENT
           *
           * O Sync genérico cria/manipula
           * somente Equipment CUSTOMER.
           *
           * Equipment ORGANIZATION será
           * gerenciado futuramente pelo
           * EquipmentAcquisitionService.
           */
          else if (
            entityUpper ===
            'EQUIPMENT'
          ) {
            if (
              entry.operationType ===
              'CREATE' ||
              entry.operationType ===
              'UPDATE'
            ) {
              assertGenericEquipmentSyncPayload(
                entry.payload
              );

              const customerId =
                entry.payload
                  .customer_id ??
                entry.payload
                  .customerId;

              if (!customerId) {
                throw new Error(
                  'EQUIPMENT requires customerId'
                );
              }

              /**
               * Customer precisa estar relacionado
               * e ativo na Organization atual.
               */
              const customerRelation =
                await tx.customerOrganization.findUnique({
                  where: {
                    customerId_organizationId: {
                      customerId,
                      organizationId,
                    },
                  },
                });

              if (
                !customerRelation
              ) {
                throw new ForbiddenError(
                  'Equipment customer does not belong to the authenticated organization'
                );
              }

              if (
                customerRelation.status !==
                'ACTIVE'
              ) {
                throw new ForbiddenError(
                  'Equipment customer relationship is not active in the authenticated organization'
                );
              }

              /**
               * Se o equipamento já existe,
               * o Sync genérico não pode assumir
               * um equipamento da Organization.
               */
              const existingEquipment =
                await tx.equipment.findUnique({
                  where: {
                    id:
                      entry.entityId,
                  },

                  select: {
                    customerId:
                      true,

                    organizationId:
                      true,

                    ownerType:
                      true,
                  },
                });

              if (
                existingEquipment
              ) {
                if (
                  existingEquipment.ownerType ===
                  EquipmentOwnerType.ORGANIZATION
                ) {
                  throw new ForbiddenError(
                    'Organization-owned equipment cannot be modified through generic Equipment Sync'
                  );
                }

                /**
                 * Não permite transferir Equipment
                 * de um Customer para outro através
                 * de UPDATE.
                 */
                if (
                  existingEquipment.customerId !==
                  customerId
                ) {
                  throw new ForbiddenError(
                    'Equipment cannot be reassigned to another Customer through Sync'
                  );
                }
              }

              await tx.equipment.upsert({
                where: {
                  id:
                    entry.entityId,
                },

                create: {
                  id:
                    entry.entityId,

                  customerId,

                  organizationId:
                    null,

                  ownerType:
                    EquipmentOwnerType.CUSTOMER,

                  organizationPurpose:
                    null,

                  type:
                    entry.payload.type,

                  brand:
                    entry.payload.brand,

                  model:
                    entry.payload.model,

                  serialNumber:
                    entry.payload
                      .serial_number ??
                    entry.payload
                      .serialNumber ??
                    null,

                  notes:
                    entry.payload.notes ??
                    null,
                },

                /**
                 * Ownership nunca é atualizado
                 * pelo Sync genérico.
                 */
                update: {
                  type:
                    entry.payload.type,

                  brand:
                    entry.payload.brand,

                  model:
                    entry.payload.model,

                  serialNumber:
                    entry.payload
                      .serial_number ??
                    entry.payload
                      .serialNumber ??
                    null,

                  notes:
                    entry.payload.notes ??
                    null,
                },
              });
            } else if (
              entry.operationType ===
              'DELETE'
            ) {
              const existingEquipment =
                await tx.equipment.findUnique({
                  where: {
                    id:
                      entry.entityId,
                  },

                  select: {
                    ownerType:
                      true,

                    customerId:
                      true,

                    organizationId:
                      true,
                  },
                });

              if (
                !existingEquipment
              ) {
                /**
                 * DELETE idempotente:
                 * já não existe.
                 */
                return;
              }

              /**
               * Equipment pertencente à Organization
               * não pode ser removido pelo Sync
               * genérico.
               */
              if (
                existingEquipment.ownerType ===
                EquipmentOwnerType.ORGANIZATION
              ) {
                throw new ForbiddenError(
                  'Organization-owned equipment cannot be deleted through generic Equipment Sync'
                );
              }

              await tx.equipment.delete({
                where: {
                  id:
                    entry.entityId,
                },
              });
            }
          }

          /**
           * SERVICE ORDER
           */
          else if (
            entityUpper ===
            'SERVICE_ORDER'
          ) {
            if (
              entry.operationType ===
              'CREATE' ||
              entry.operationType ===
              'UPDATE'
            ) {
              const existingOS =
                await tx.serviceOrder.findUnique({
                  where: {
                    id:
                      entry.entityId,
                  },
                });

              const newStatus =
                (
                  entry.payload
                    .status as
                  ServiceOrderStatus
                ) ??
                ServiceOrderStatus
                  .DIAGNOSTICO;

              if (
                existingOS &&
                !isValidStatusTransition(
                  existingOS.status,
                  newStatus
                )
              ) {
                throw new Error(
                  `CONFLICT: Invalid status transition from ${existingOS.status} to ${newStatus}`
                );
              }

              const customerId =
                entry.payload
                  .customer_id ??
                entry.payload
                  .customerId;

              const equipmentId =
                entry.payload
                  .equipment_id ??
                entry.payload
                  .equipmentId;

              const technicianId =
                entry.payload
                  .technician_id ??
                entry.payload
                  .technicianId ??
                null;

              const problemDescription =
                entry.payload
                  .problem_description ??
                entry.payload
                  .problemDescription;

              if (!customerId) {
                throw new Error(
                  'SERVICE_ORDER requires customerId'
                );
              }

              if (!equipmentId) {
                throw new Error(
                  'SERVICE_ORDER requires equipmentId'
                );
              }

              if (
                !problemDescription
              ) {
                throw new Error(
                  'SERVICE_ORDER requires problemDescription'
                );
              }

              /**
               * Customer precisa estar relacionado
               * à Organization.
               */
              const customerRelation =
                await tx.customerOrganization.findUnique({
                  where: {
                    customerId_organizationId: {
                      customerId,
                      organizationId,
                    },
                  },
                });

              if (
                !customerRelation
              ) {
                throw new ForbiddenError(
                  'Service Order customer does not belong to the authenticated organization'
                );
              }

              if (
                customerRelation.status !==
                'ACTIVE'
              ) {
                throw new ForbiddenError(
                  'Service Order customer relationship is not active'
                );
              }

              /**
               * Equipment principal da OS precisa:
               *
               * - pertencer ao CUSTOMER;
               * - estar ligado ao mesmo customerId.
               *
               * Equipment ORGANIZATION:
               * RESALE / PARTS_DONOR / INTERNAL_USE
               * não pode ser equipamento principal
               * de uma OS de cliente.
               */
              const equipment =
                await tx.equipment.findFirst({
                  where: {
                    id:
                      equipmentId,

                    customerId,

                    ownerType:
                      EquipmentOwnerType.CUSTOMER,
                  },
                });

              if (!equipment) {
                throw new Error(
                  'Equipment does not belong to the specified customer or is not customer-owned'
                );
              }

              /**
               * Technician, quando informado,
               * precisa pertencer à Organization.
               */
              if (
                technicianId
              ) {
                const technician =
                  await tx.membership.findUnique({
                    where: {
                      userId_organizationId: {
                        userId:
                          technicianId,

                        organizationId,
                      },
                    },
                  });

                if (
                  !technician ||
                  ![
                    'ADMIN',
                    'TECHNICIAN',
                  ].includes(
                    technician.role
                  )
                ) {
                  throw new ForbiddenError(
                    'Technician does not belong to the authenticated organization'
                  );
                }
              }

              const persistedOrder =
                await tx.serviceOrder.upsert({
                  where: {
                    id:
                      entry.entityId,
                  },

                  create: {
                    id:
                      entry.entityId,

                    organizationId,

                    customerId,

                    equipmentId,

                    technicianId,

                    status:
                      newStatus,

                    problemDescription,

                    diagnosis:
                      entry.payload
                        .diagnosis ??
                      null,

                    solution:
                      entry.payload
                        .solution ??
                      null,

                    totalAmount:
                      entry.payload
                        .total_amount ??
                      entry.payload
                        .totalAmount ??
                      0,
                  },

                  update: {
                    status:
                      newStatus,

                    diagnosis:
                      entry.payload
                        .diagnosis ??
                      null,

                    solution:
                      entry.payload
                        .solution ??
                      null,

                    totalAmount:
                      entry.payload
                        .total_amount ??
                      entry.payload
                        .totalAmount ??
                      0,
                  },
                });
              /**
               * CLIENT_GATE_SERVICE_ORDER_DOMAIN_EFFECTS
               *
               * Reutiliza os efeitos já consolidados
               * no domínio REST.
               */
              if (
                !existingOS &&
                entry.operationType ===
                'CREATE'
              ) {
                await serviceOrderCustomerRelationshipService
                  .registerCreated(
                    {
                      serviceOrderId:
                        persistedOrder.id,

                      customerId:
                        persistedOrder.customerId,

                      organizationId:
                        persistedOrder.organizationId,

                      status:
                        persistedOrder.status,
                    },

                    tx
                  );
              } else if (
                existingOS &&
                existingOS.status !==
                persistedOrder.status
              ) {
                await tx.serviceOrderStatusHistory.create({
                  data: {
                    serviceOrderId:
                      persistedOrder.id,

                    previousStatus:
                      existingOS.status,

                    newStatus:
                      persistedOrder.status,

                    changedById:
                      authenticatedUserId,
                  },
                });

                await serviceOrderCustomerRelationshipService
                  .registerStatusTransition(
                    {
                      serviceOrderId:
                        persistedOrder.id,

                      customerId:
                        persistedOrder.customerId,

                      organizationId:
                        persistedOrder.organizationId,

                      previousStatus:
                        existingOS.status,

                      newStatus:
                        persistedOrder.status,
                    },

                    tx
                  );
              }
            } else if (
              entry.operationType ===
              'DELETE'
            ) {
              await tx.serviceOrder
                .delete({
                  where: {
                    id:
                      entry.entityId,
                  },
                })
                .catch(
                  () =>
                    null
                );
            }
          }

          /**
           * PART
           *
           * Atualmente Part ainda é global,
           * pois não possui organizationId.
           */
          else if (
            entityUpper ===
            'PART'
          ) {
            if (
              entry.operationType ===
              'CREATE' ||
              entry.operationType ===
              'UPDATE'
            ) {
              await tx.part.upsert({
                where: {
                  id:
                    entry.entityId,
                },

                create: {
                  id:
                    entry.entityId,

                  name:
                    entry.payload.name,

                  sku:
                    entry.payload.sku,

                  price:
                    entry.payload.price,

                  costPrice:
                    entry.payload
                      .cost_price ??
                    entry.payload
                      .costPrice ??
                    0,

                  stockQuantity:
                    entry.payload
                      .stock_quantity ??
                    entry.payload
                      .stockQuantity ??
                    0,
                },

                update: {
                  name:
                    entry.payload.name,

                  sku:
                    entry.payload.sku,

                  price:
                    entry.payload.price,

                  costPrice:
                    entry.payload
                      .cost_price ??
                    entry.payload
                      .costPrice ??
                    0,

                  stockQuantity:
                    entry.payload
                      .stock_quantity ??
                    entry.payload
                      .stockQuantity ??
                    0,
                },
              });
            } else if (
              entry.operationType ===
              'DELETE'
            ) {
              await tx.part
                .delete({
                  where: {
                    id:
                      entry.entityId,
                  },
                })
                .catch(
                  () =>
                    null
                );
            }
          }

          /**
           * SERVICE ORDER ITEM
           */
          else if (
            entityUpper ===
            'SERVICE_ORDER_ITEM'
          ) {
            if (
              entry.operationType ===
              'CREATE' ||
              entry.operationType ===
              'UPDATE'
            ) {
              const serviceOrderId =
                entry.payload
                  .service_order_id ??
                entry.payload
                  .serviceOrderId;

              if (
                !serviceOrderId
              ) {
                throw new Error(
                  'SERVICE_ORDER_ITEM requires serviceOrderId'
                );
              }

              const serviceOrder =
                await tx.serviceOrder.findUnique({
                  where: {
                    id:
                      serviceOrderId,
                  },

                  select: {
                    organizationId:
                      true,

                    customerId:
                      true,
                  },
                });

              if (
                !serviceOrder
              ) {
                throw new Error(
                  'Service Order not found'
                );
              }

              if (
                serviceOrder.organizationId !==
                organizationId
              ) {
                throw new ForbiddenError(
                  'Service Order Item does not belong to the authenticated organization'
                );
              }

              if (
                authUser.role ===
                'CUSTOMER' &&
                serviceOrder.customerId !==
                authUser.customerId
              ) {
                throw new ForbiddenError(
                  'CUSTOMER cannot modify another Customer Service Order Item'
                );
              }

              await tx.serviceOrderItem.upsert({
                where: {
                  id:
                    entry.entityId,
                },

                create: {
                  id:
                    entry.entityId,

                  serviceOrderId,

                  partId:
                    entry.payload
                      .part_id ??
                    entry.payload
                      .partId ??
                    null,

                  description:
                    entry.payload
                      .description,

                  quantity:
                    entry.payload
                      .quantity ??
                    1,

                  unitPrice:
                    entry.payload
                      .unit_price ??
                    entry.payload
                      .unitPrice ??
                    0,

                  totalPrice:
                    entry.payload
                      .total_price ??
                    entry.payload
                      .totalPrice ??
                    0,
                },

                update: {
                  description:
                    entry.payload
                      .description,

                  quantity:
                    entry.payload
                      .quantity ??
                    1,

                  unitPrice:
                    entry.payload
                      .unit_price ??
                    entry.payload
                      .unitPrice ??
                    0,

                  totalPrice:
                    entry.payload
                      .total_price ??
                    entry.payload
                      .totalPrice ??
                    0,
                },
              });
            } else if (
              entry.operationType ===
              'DELETE'
            ) {
              await tx.serviceOrderItem
                .delete({
                  where: {
                    id:
                      entry.entityId,
                  },
                })
                .catch(
                  () =>
                    null
                );
            }
          }

          /**
           * Tipo desconhecido.
           */
          else {
            throw new Error(
              `Unsupported entity type: ${entry.entityType}`
            );
          }

          /**
           * CLIENT_GATE_CANONICAL_SERVICE_ORDER_CHANGELOG
           *
           * ServiceOrder publica o estado canônico
           * realmente persistido.
           */
          if (
            entityUpper ===
            'SERVICE_ORDER' &&
            entry.operationType !==
            'DELETE'
          ) {
            const canonicalOrder =
              await tx.serviceOrder.findUniqueOrThrow({
                where: {
                  id:
                    entry.entityId,
                },
              });

            await recordServiceOrderSyncChange(
              canonicalOrder,
              entry.operationType,
              tx
            );
          } else {
            const changeLog =
              await tx.syncChangeLog.create({
                data: {
                  cursor:
                    entry.operationId,

                  entityType:
                    entry.entityType,

                  entityId:
                    entry.entityId,

                  operationType:
                    entry.operationType,

                  data:
                    entry.payload,
                },
              });

            await tx.syncChangeLog.update({
              where: {
                id:
                  changeLog.id,
              },

              data: {
                cursor:
                  changeLog.id.toString(),
              },
            });
          }
        }
      );

      /**
       * Atualiza resultado da
       * idempotência após sucesso.
       */
      await prisma.operationIdempotency
        .update({
          where: {
            operationId:
              entry.operationId,
          },

          data: {
            responseBody: {
              status:
                'SYNCED',
            },

            responseStatus:
              200,

            status:
              'COMPLETED',

            completedAt:
              new Date(),

            processingExpiresAt:
              null,
          },
        })
        .catch(
          () => { }
        );

      results.push({
        operationId:
          entry.operationId,

        status:
          'SYNCED',
      });
    } catch (
    err: any
    ) {
      /**
       * CLIENT_GATE_RELEASE_FAILED_IDEMPOTENCY
       *
       * Falha de domínio libera apenas a reserva
       * PROCESSING daquela operationId.
       */
      await prisma.operationIdempotency.deleteMany({
        where: {
          operationId:
            entry.operationId,

          status:
            'PROCESSING',

          responseStatus:
            102,
        },
      })
        .catch(
          () => { }
        );
      results.push({
        operationId:
          entry.operationId,

        status:
          'FAILED',

        error:
          err?.message ??
          'Unknown processing error',
      });
    }
  }

  return reply
    .status(200)
    .send({
      results,
    });
}

/**
 * PULL SYNC
 */
export async function pullSyncHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const query =
    pullSyncQuerySchema.parse(
      request.query
    );

  const authUser =
    getAuthUser(
      request
    );

  let cursorId =
    0n;

  if (query.cursor) {
    try {
      cursorId =
        BigInt(
          query.cursor
        );
    } catch {
      cursorId =
        0n;
    }
  }

  const baseWhere =
    cursorId > 0n
      ? {
        id: {
          gt:
            cursorId,
        },
      }
      : {};

  const organizationId =
    authUser.role ===
      'CUSTOMER'
      ? null
      : await getAuthenticatedOrganizationId(
        authUser.sub,
        authUser.role,
        authUser.customerId
      );

  let authorizedEntityIds:
    Set<string>;

  /**
   * CUSTOMER
   */
  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    const customerId =
      authUser.customerId;

    if (!customerId) {
      return reply
        .status(403)
        .send({
          error:
            'CUSTOMER user has no associated Customer identity',
        });
    }

    const [
      equipments,
      serviceOrders,
    ] =
      await Promise.all([
        /**
         * CUSTOMER vê equipamentos
         * atualmente pertencentes a ele.
         *
         * Equipment transferido para uma
         * Organization passa a ter
         * customerId = null e deixa
         * naturalmente esta lista.
         */
        prisma.equipment.findMany({
          where: {
            customerId,

            ownerType:
              EquipmentOwnerType.CUSTOMER,
          },

          select: {
            id:
              true,
          },
        }),

        /**
         * CUSTOMER global:
         *
         * todas as próprias OS,
         * independentemente da Organization.
         */
        prisma.serviceOrder.findMany({
          where: {
            customerId,
          },

          select: {
            id: true,
          },
        }),
      ]);
    const serviceOrderIds =
      serviceOrders.map(
        (order) =>
          order.id
      );

    const serviceOrderItems =
      serviceOrderIds.length >
        0
        ? await prisma.serviceOrderItem.findMany({
          where: {
            serviceOrderId: {
              in:
                serviceOrderIds,
            },
          },

          select: {
            id:
              true,
          },
        })
        : [];

    authorizedEntityIds =
      new Set<string>([
        customerId,

        ...equipments.map(
          (equipment) =>
            equipment.id
        ),

        ...serviceOrderIds,

        ...serviceOrderItems.map(
          (item) =>
            item.id
        ),
      ]);
  }

  /**
   * ADMIN / TECHNICIAN
   */
  else {
    /**
     * ADMIN / TECHNICIAN sempre precisam operar
     * dentro de um contexto organizacional.
     *
     * O narrowing explícito também garante ao TypeScript
     * que organizationId é string neste ramo.
     */
    if (!organizationId) {
      throw new ForbiddenError(
        'Organization context is required'
      );
    }

    const [
      customerRelations,
      equipments,
      serviceOrders,
      payments,
    ] =
      await Promise.all([
        /**
         * Customers relacionados
         * à Organization.
         */
        prisma.customerOrganization.findMany({
          where: {
            organizationId,

            status:
              'ACTIVE',
          },

          select: {
            customerId:
              true,
          },
        }),

        /**
         * Equipment visível à Organization:
         *
         * 1. pertence diretamente a ela;
         *
         * OU
         *
         * 2. pertence a Customer e existe
         *    pelo menos uma OS desta Organization
         *    utilizando esse Equipment.
         */
        prisma.equipment.findMany({
          where: {
            OR: [
              {
                ownerType:
                  EquipmentOwnerType.ORGANIZATION,

                organizationId,
              },

              {
                ownerType:
                  EquipmentOwnerType.CUSTOMER,

                serviceOrders: {
                  some: {
                    organizationId,
                  },
                },
              },
            ],
          },

          select: {
            id:
              true,
          },
        }),

        /**
         * Todas as OS da Organization.
         */
        prisma.serviceOrder.findMany({
          where: {
            organizationId,
          },

          select: {
            id:
              true,
          },
        }),

        /**
         * Pagamentos somente das OS
         * pertencentes à Organization.
         */
        prisma.payment.findMany({
          where: {
            organizationId,
          },

          select: {
            id:
              true,
          },
        }),
      ]);

    const customerIds =
      customerRelations.map(
        (relation) =>
          relation.customerId
      );

    const equipmentIds =
      equipments.map(
        (equipment) =>
          equipment.id
      );

    const serviceOrderIds =
      serviceOrders.map(
        (order) =>
          order.id
      );

    const paymentIds =
      payments.map(
        (payment) =>
          payment.id
      );

    /**
     * Part ainda e global no schema atual.
     *
     * O frontend possui suporte a PART no Sync Pull,
     * portanto ADMIN/TECH precisam autorizar os IDs globais
     * ate a futura modelagem multi-tenant do estoque.
     */
    const partIdsForPull =
      (
        await prisma.part.findMany({
          select: {
            id:
              true,
          },
        })
      ).map(
        (part) =>
          part.id
      );

    const serviceOrderItems =
      serviceOrderIds.length >
        0
        ? await prisma.serviceOrderItem.findMany({
          where: {
            serviceOrderId: {
              in:
                serviceOrderIds,
            },
          },

          select: {
            id:
              true,
          },
        })
        : [];

    authorizedEntityIds =
      new Set<string>([
        ...customerIds,

        ...equipmentIds,

        ...serviceOrderIds,

        ...serviceOrderItems.map(
          (item) =>
            item.id
        ),

        ...paymentIds,

        ...partIdsForPull,
      ]);
  }

  /**
   * Busca alterações após cursor.
   */
  const allChanges =
    await prisma.syncChangeLog.findMany({
      where:
        baseWhere,

      orderBy: {
        id:
          'asc',
      },

      take:
        query.limit,
    });

  /**
   * Filtra somente entidades
   * que o usuário atual pode receber.
   */
  const changes =
    allChanges.filter(
      (change) => {
        /**
         * FIN_F01_CUSTOMER_PAYMENT_PULL_DENY
         *
         * CUSTOMER is outside Finance V1.
         * Deny PAYMENT by entity type in addition to ID authorization
         * so an authorized entity-ID collision cannot expose Payment
         * SyncChangeLog payloads.
         */
        if (
          authUser.role ===
            'CUSTOMER' &&
          change.entityType
            .toUpperCase() ===
            'PAYMENT'
        ) {
          return false;
        }

        return authorizedEntityIds.has(
          change.entityId
        );
      }
    );

  /**
   * O cursor representa o ultimo registro EXAMINADO,
   * e nao apenas o ultimo registro autorizado.
   *
   * Assim, um lote contendo somente mudancas de outro tenant
   * nao prende o cliente em um loop relendo o mesmo lote.
   */
  const nextCursor =
    allChanges.length > 0
      ? allChanges[
        allChanges.length -
        1
      ].id.toString()
      : query.cursor ??
      '0';

  return reply
    .status(200)
    .send({
      nextCursor,

      changes:
        changes.map(
          (change) => ({
            cursor:
              change.id.toString(),

            entityType:
              change.entityType,

            entityId:
              change.entityId,

            operationType:
              change.operationType,

            data:
              change.data,

            createdAt:
              change.createdAt,
          })
        ),
    });
}
