import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import {
  z,
} from 'zod';

import {
  CustomerEventType,
  EquipmentOwnerType,
  OperationType,
  ServiceOrderStatus,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  ConflictError,
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  serviceOrderCustomerRelationshipService,
} from '../customer_relationship/service_order_customer_relationship.service.js';

import {
  recordServiceOrderSyncChange,
} from '../../core/sync/sync_change_log.service.js';

import {
  ALLOWED_TRANSITIONS,
  isFinanceCommandOnlyStatusTransition,
  isValidStatusTransition,
} from './service_order_state_machine.js';

const newEquipmentSchema =
  z.object({
    type:
      z.string()
        .trim()
        .min(1),

    brand:
      z.string()
        .trim()
        .min(1),

    model:
      z.string()
        .trim()
        .min(1),

    serialNumber:
      z.string()
        .trim()
        .min(1)
        .optional(),

    notes:
      z.string()
        .trim()
        .optional(),
  });


const createOrderSchema =
  z.object({
    customerId:
      z.string().uuid(),

    /**
     * Equipment já conhecido pela
     * Organization através de OS anterior.
     */
    equipmentId:
      z.string()
        .uuid()
        .optional(),

    /**
     * Primeiro atendimento desse Equipment.
     *
     * Equipment + OS serão criados
     * atomicamente.
     */
    equipment:
      newEquipmentSchema
        .optional(),

    technicianId:
      z.string()
        .uuid()
        .optional(),

    problemDescription:
      z.string()
        .trim()
        .min(1),
  })
    .superRefine(
      (
        data,
        ctx
      ) => {
        const hasEquipmentId =
          Boolean(
            data.equipmentId
          );

        const hasNewEquipment =
          Boolean(
            data.equipment
          );

        /**
         * Exatamente UMA das opções
         * deve ser informada.
         */
        if (
          hasEquipmentId ===
          hasNewEquipment
        ) {
          ctx.addIssue({
            code:
              z.ZodIssueCode
                .custom,

            message:
              'Provide either equipmentId or equipment, but not both',
          });
        }
      }
    );

const updateStatusSchema =
  z.object({
    newStatus:
      z.nativeEnum(
        ServiceOrderStatus
      ),

    notes:
      z.string().optional(),
  });

const notApprovedSchema =
  z.object({
    reason:
      z.string()
        .trim()
        .min(1)
        .max(1000)
        .optional(),
  });

export async function listServiceOrdersHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  let whereClause;

  /**
   * CUSTOMER:
   *
   * identidade global.
   * Todas as próprias OS.
   */
  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    if (
      !authUser.customerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER user has no associated Customer identity'
      );
    }

    whereClause = {
      customerId:
        authUser.customerId,
    };
  } else {
    /**
     * ADMIN / TECH:
     * tenant obrigatório.
     */
    const organizationId =
      requireOrganizationId(
        authUser
      );

    whereClause = {
      organizationId,
    };
  }

  const orders =
    await prisma
      .serviceOrder
      .findMany({
        where:
          whereClause,

        include: {
          organization: {
            select: {
              id:
                true,

              name:
                true,
            },
          },

          customer:
            true,

          equipment:
            true,

          technician: {
            select: {
              id:
                true,

              name:
                true,
            },
          },
        },

        orderBy: {
          createdAt:
            'desc',
        },
      });

  return reply.send({
    orders,
  });
}

export async function getServiceOrderHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      request
    );

  let whereClause;

  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    if (
      !authUser.customerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER user has no associated Customer identity'
      );
    }

    /**
     * CUSTOMER:
     *
     * id + customerId.
     *
     * Não usamos organizationId.
     */
    whereClause = {
      id,

      customerId:
        authUser.customerId,
    };
  } else {
    const organizationId =
      requireOrganizationId(
        authUser
      );

    whereClause = {
      id,
      organizationId,
    };
  }

  const order =
    await prisma
      .serviceOrder
      .findFirst({
        where:
          whereClause,

        include: {
          organization: {
            select: {
              id:
                true,

              name:
                true,
            },
          },

          customer:
            true,

          equipment:
            true,

          technician: {
            select: {
              id:
                true,

              name:
                true,
            },
          },
        },
      });

  /**
   * CUSTOMER tentando OS alheia
   * também recebe 404.
   */
  if (!order) {
    return reply
      .status(404)
      .send({
        error:
          'Service Order not found',
      });
  }

  return reply.send({
    order,
  });
}

export async function createServiceOrderHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body =
    createOrderSchema.parse(
      request.body
    );

  const authUser =
    getAuthUser(
      request
    );

  const organizationId =
    requireOrganizationId(
      authUser
    );
  /**
   * ========================================================
   * CUSTOMER × ORGANIZATION
   * ========================================================
   */

  const customerOrganization =
    await prisma
      .customerOrganization
      .findUnique({
        where: {
          customerId_organizationId: {
            customerId:
              body.customerId,

            organizationId:
              organizationId,
          },
        },
      });

  if (
    !customerOrganization
  ) {
    throw new ForbiddenError(
      'Customer does not belong to the current organization'
    );
  }

  if (
    customerOrganization.status !==
    'ACTIVE'
  ) {
    throw new ForbiddenError(
      'Customer relationship with the current organization is not active'
    );
  }

  /**
   * ========================================================
   * TECHNICIAN
   * ========================================================
   */

  if (
    body.technicianId
  ) {
    const technician =
      await prisma
        .membership
        .findUnique({
          where: {
            userId_organizationId: {
              userId:
                body.technicianId,

              organizationId:
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
        'Technician does not belong to the current organization'
      );
    }
  }

  /**
   * ========================================================
   * EQUIPMENT EXISTENTE
   * ========================================================
   *
   * equipmentId somente pode ser reutilizado
   * quando:
   *
   * 1. pertence ao Customer;
   * 2. continua sendo CUSTOMER-owned;
   * 3. a Organization já possui uma OS
   *    relacionada a esse Equipment.
   *
   * CustomerOrganization sozinho NÃO concede
   * acesso ao Equipment.
   */

  let existingEquipmentId:
    string | null =
    null;

  if (
    body.equipmentId
  ) {
    const equipment =
      await prisma
        .equipment
        .findFirst({
          where: {
            id:
              body.equipmentId,

            customerId:
              body.customerId,

            ownerType:
              EquipmentOwnerType
                .CUSTOMER,

            serviceOrders: {
              some: {
                organizationId,
              },
            },
          },

          select: {
            id:
              true,
          },
        });

    if (
      !equipment
    ) {
      /**
       * Mensagem propositalmente genérica.
       *
       * Não informamos se:
       * - Equipment não existe;
       * - pertence a outro Customer;
       * - pertence a outro tenant;
       * - ainda não foi atendido pela Organization.
       */
      throw new ForbiddenError(
        'Equipment is not available to the current organization'
      );
    }

    existingEquipmentId =
      equipment.id;
  }

  /**
   * ========================================================
   * TRANSACTION
   * ========================================================
   *
   * Primeiro atendimento:
   *
   * Equipment
   *     +
   * ServiceOrder
   *     +
   * CRM
   *
   * Tudo ou nada.
   */

  const order =
    await prisma
      .$transaction(
        async (tx) => {
          let equipmentId =
            existingEquipmentId;

          /**
           * Primeiro atendimento
           * daquele equipamento.
           */
          if (
            body.equipment
          ) {
            const createdEquipment =
              await tx
                .equipment
                .create({
                  data: {
                    customerId:
                      body.customerId,

                    organizationId:
                      null,

                    ownerType:
                      EquipmentOwnerType
                        .CUSTOMER,

                    organizationPurpose:
                      null,

                    type:
                      body.equipment
                        .type,

                    brand:
                      body.equipment
                        .brand,

                    model:
                      body.equipment
                        .model,

                    serialNumber:
                      body.equipment
                        .serialNumber,

                    notes:
                      body.equipment
                        .notes,
                  },
                });

            equipmentId =
              createdEquipment.id;
          }

          /**
           * Impossível após validação Zod,
           * mas mantemos defesa interna.
           */
          if (
            !equipmentId
          ) {
            throw new ConflictError(
              'Service Order requires an Equipment'
            );
          }

          const createdOrder =
            await tx
              .serviceOrder
              .create({
                data: {
                  organizationId,

                  customerId:
                    body.customerId,

                  equipmentId,

                  technicianId:
                    body.technicianId,

                  problemDescription:
                    body.problemDescription,

                  status:
                    ServiceOrderStatus
                      .DIAGNOSTICO,

                  /**
                   * FIN-F02 cutover is server-owned.
                   * Client input never selects this value.
                   */
                  financeCoreVersion:
                    2,
                },
              });

          await serviceOrderCustomerRelationshipService
            .registerCreated(
              {
                serviceOrderId:
                  createdOrder.id,

                customerId:
                  createdOrder
                    .customerId,

                organizationId:
                  createdOrder
                    .organizationId,

                status:
                  createdOrder
                    .status,
              },

              tx
            );

          
          await recordServiceOrderSyncChange(
            createdOrder,
            OperationType.CREATE,
            tx
          );

          return createdOrder;
        }
      );

  return reply
    .status(201)
    .send({
      order,
    });
}

export async function updateServiceOrderStatusHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const { id } =
    request.params as {
      id: string;
    };

  const body =
    updateStatusSchema.parse(
      request.body
    );

  const authUser =
    getAuthUser(
      request
    );
  const organizationId =
    requireOrganizationId(
      authUser
    );
  const changedById =
    authUser.sub;

  const order =
    await prisma
      .serviceOrder
      .findFirst({
        where: {
          id,

          organizationId:
            organizationId,
        },
      });

  if (!order) {
    return reply
      .status(404)
      .send({
        error:
          'Service Order not found',
      });
  }

  /**
   * Retry/idempotência.
   */
  if (
    order.status ===
    body.newStatus
  ) {
    return reply.send({
      order,
    });
  }

  /**
   * FIN-F02 generic status firewall.
   *
   * Command-only edges are rejected even if they are valid
   * domain transitions.
   */
  if (
    isFinanceCommandOnlyStatusTransition(
      order.status,
      body.newStatus,
      order.financeCoreVersion
    )
  ) {
    return reply
      .status(409)
      .send({
        error:
          'FINANCE_COMMAND_REQUIRED',
      });
  }

  if (
    !isValidStatusTransition(
      order.status,
      body.newStatus
    )
  ) {
    return reply
      .status(409)
      .send({
        error:
          `Invalid status transition from ` +
          `${order.status} to ${body.newStatus}`,

        allowedTransitions:
          ALLOWED_TRANSITIONS[
          order.status
          ] || [],
      });
  }

  const updatedOrder =
    await prisma
      .$transaction(
        async (tx) => {
          /**
           * Optimistic locking.
           */
          const updateResult =
            await tx
              .serviceOrder
              .updateMany({
                where: {
                  id,

                  organizationId:
                    organizationId,

                  status:
                    order.status,
                },

                data: {
                  status:
                    body.newStatus,
                },
              });

          if (
            updateResult.count !==
            1
          ) {
            throw new ConflictError(
              'Service Order status changed concurrently. Reload the order and try again.'
            );
          }

          await tx
            .serviceOrderStatusHistory
            .create({
              data: {
                serviceOrderId:
                  id,

                previousStatus:
                  order.status,

                newStatus:
                  body.newStatus,

                changedById,

                notes:
                  body.notes,
              },
            });

          const updated =
            await tx
              .serviceOrder
              .findUniqueOrThrow({
                where: {
                  id,
                },
              });

          await serviceOrderCustomerRelationshipService
            .registerStatusTransition(
              {
                serviceOrderId:
                  updated.id,

                customerId:
                  updated.customerId,

                organizationId:
                  updated.organizationId,

                previousStatus:
                  order.status,

                newStatus:
                  updated.status,
              },

              tx
            );

          
          await recordServiceOrderSyncChange(
            updated,
            OperationType.UPDATE,
            tx
          );

          return updated;
        }
      );

  return reply.send({
    order:
      updatedOrder,
  });
}

/**
 * Cliente recusou explicitamente
 * o orçamento apresentado.
 */
export async function markServiceOrderNotApprovedHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const { id } =
    request.params as {
      id: string;
    };

  const body =
    notApprovedSchema.parse(
      request.body ?? {}
    );

  const authUser =
    getAuthUser(
      request
    );

  const organizationId =
    requireOrganizationId(
      authUser
    );
  const order =
    await prisma
      .serviceOrder
      .findFirst({
        where: {
          id,

          organizationId:
            organizationId,
        },
      });

  if (!order) {
    return reply
      .status(404)
      .send({
        error:
          'Service Order not found',
      });
  }

  /**
   * FIN-F02 decisions must target the exact immutable
   * QuoteRevision and are not delegated to staff.
   */
  if (
    order.financeCoreVersion ===
    2
  ) {
    return reply
      .status(409)
      .send({
        error:
          'FIN_F02_EXACT_QUOTE_DECISION_REQUIRED',
      });
  }

  /**
   * Retry idempotente.
   */
  const existingEvent =
    await prisma
      .customerEvent
      .findFirst({
        where: {
          organizationId:
            organizationId,

          serviceOrderId:
            order.id,

          type:
            CustomerEventType
              .SERVICE_ORDER_NOT_APPROVED,
        },
      });

  if (existingEvent) {
    return reply.send({
      order,

      alreadyProcessed:
        true,
    });
  }

  /**
   * Uma recusa só pode ocorrer quando
   * o orçamento aguarda aprovação.
   */
  if (
    order.status !==
    ServiceOrderStatus
      .AGUARDANDO_APROVACAO
  ) {
    return reply
      .status(409)
      .send({
        error:
          'Service Order is not awaiting approval',

        currentStatus:
          order.status,

        requiredStatus:
          ServiceOrderStatus
            .AGUARDANDO_APROVACAO,
      });
  }

  const updatedOrder =
    await prisma
      .$transaction(
        async (tx) => {
          const result =
            await tx
              .serviceOrder
              .updateMany({
                where: {
                  id:
                    order.id,

                  organizationId:
                    organizationId,

                  status:
                    ServiceOrderStatus
                      .AGUARDANDO_APROVACAO,
                },

                data: {
                  status:
                    ServiceOrderStatus
                      .CANCELADO,
                },
              });

          if (
            result.count !==
            1
          ) {
            throw new ConflictError(
              'Service Order status changed concurrently. Reload the order and try again.'
            );
          }

          await tx
            .serviceOrderStatusHistory
            .create({
              data: {
                serviceOrderId:
                  order.id,

                previousStatus:
                  ServiceOrderStatus
                    .AGUARDANDO_APROVACAO,

                newStatus:
                  ServiceOrderStatus
                    .CANCELADO,

                changedById:
                  authUser.sub,

                notes:
                  body.reason ??
                  'Orçamento não aprovado pelo cliente',
              },
            });

          /**
           * Não usamos registerStatusTransition()
           * aqui para não gerar
           * SERVICE_ORDER_CANCELLED.
           */
          await serviceOrderCustomerRelationshipService
            .registerNotApproved(
              {
                serviceOrderId:
                  order.id,

                customerId:
                  order.customerId,

                organizationId:
                  order.organizationId,

                previousStatus:
                  order.status,

                changedById:
                  authUser.sub,

                reason:
                  body.reason,
              },

              tx
            );

          return tx
            .serviceOrder
            .findUniqueOrThrow({
              where: {
                id:
                  order.id,
              },
            });
        }
      );

  return reply.send({
    order:
      updatedOrder,
  });
}


