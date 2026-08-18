import { FastifyRequest, FastifyReply } from 'fastify';
import { ServiceOrderStatus } from '@prisma/client';
import { prisma } from '../../core/database/prisma.js';
import { pushSyncSchema, pullSyncQuerySchema } from './sync.schema.js';
import { computePayloadHash } from '../../core/middleware/idempotency.middleware.js';
import { isValidStatusTransition } from '../service_orders/service_order_state_machine.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ForbiddenError } from '../../core/utils/errors.js';

/**
 * P0.5:
 * Atomically reserves an idempotency slot by attempting a DB insert.
 */
async function reserveIdempotencySlot(
  operationId: string,
  currentHash: string,
  userId: string,
  deviceId?: string
): Promise<
  | { isNew: true }
  | {
    isNew: false;
    conflict: boolean;
    responseBody?: unknown;
  }
> {
  try {
    await prisma.operationIdempotency.create({
      data: {
        operationId,
        endpoint: '/api/v1/sync/push',
        requestHash: currentHash,
        responseStatus: 200,
        responseBody: {},
        userId,
        deviceId: deviceId ?? null,
      },
    });

    return { isNew: true };
  } catch (err: any) {
    // P2002 = unique constraint violation
    if (err?.code === 'P2002') {
      const existing = await prisma.operationIdempotency.findUnique({
        where: { operationId },
      });

      if (!existing) {
        return { isNew: true };
      }

      if (existing.requestHash !== currentHash) {
        return {
          isNew: false,
          conflict: true,
        };
      }

      return {
        isNew: false,
        conflict: false,
        responseBody: existing.responseBody,
      };
    }

    throw err;
  }
}

/**
 * Obtains the organization associated with the authenticated user.
 *
 * ADMIN / TECHNICIAN:
 *   organization comes from Membership.
 *
 * CUSTOMER:
 *   organization comes from the active CustomerOrganization relation.
 *
 * The client NEVER supplies organizationId as the source of authority.
 */
async function getAuthenticatedOrganizationId(
  userId: string,
  role: string,
  customerId: string | null
): Promise<string> {
  if (role === 'CUSTOMER') {
    if (!customerId) {
      throw new ForbiddenError(
        'CUSTOMER user has no associated Customer identity'
      );
    }

    const customerOrganization =
      await prisma.customerOrganization.findFirst({
        where: {
          customerId,
          status: 'ACTIVE',
        },
        orderBy: {
          createdAt: 'asc',
        },
        select: {
          organizationId: true,
        },
      });

    if (!customerOrganization) {
      throw new ForbiddenError(
        'Customer is not associated with an active organization'
      );
    }

    return customerOrganization.organizationId;
  }

  const membership = await prisma.membership.findFirst({
    where: {
      userId,
    },
    orderBy: {
      createdAt: 'asc',
    },
    select: {
      organizationId: true,
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
 * Validates whether an entity belongs to the authenticated organization.
 *
 * This is especially important for ADMIN / TECHNICIAN users.
 * Having a valid JWT does NOT mean that the user can manipulate
 * another organization's data.
 */
async function validateOrganizationOwnership(
  entityType: string,
  entityId: string,
  organizationId: string
): Promise<void> {
  const entityUpper = entityType.toUpperCase();

  if (entityUpper === 'CUSTOMER') {
    const relation = await prisma.customerOrganization.findUnique({
      where: {
        customerId_organizationId: {
          customerId: entityId,
          organizationId,
        },
      },
    });

    if (!relation) {
      throw new ForbiddenError(
        'Customer does not belong to the authenticated organization'
      );
    }

    return;
  }

  if (entityUpper === 'EQUIPMENT') {
    const equipment = await prisma.equipment.findUnique({
      where: {
        id: entityId,
      },
      select: {
        customerId: true,
      },
    });

    if (!equipment) {
      return;
    }

    const relation = await prisma.customerOrganization.findUnique({
      where: {
        customerId_organizationId: {
          customerId: equipment.customerId,
          organizationId,
        },
      },
    });

    if (!relation) {
      throw new ForbiddenError(
        'Equipment does not belong to the authenticated organization'
      );
    }

    return;
  }

  if (entityUpper === 'SERVICE_ORDER') {
    const order = await prisma.serviceOrder.findUnique({
      where: {
        id: entityId,
      },
      select: {
        organizationId: true,
      },
    });

    if (order && order.organizationId !== organizationId) {
      throw new ForbiddenError(
        'Service Order does not belong to the authenticated organization'
      );
    }

    return;
  }

  if (entityUpper === 'SERVICE_ORDER_ITEM') {
    const item = await prisma.serviceOrderItem.findUnique({
      where: {
        id: entityId,
      },
      select: {
        serviceOrder: {
          select: {
            organizationId: true,
          },
        },
      },
    });

    if (
      item &&
      item.serviceOrder.organizationId !== organizationId
    ) {
      throw new ForbiddenError(
        'Service Order Item does not belong to the authenticated organization'
      );
    }

    return;
  }

  if (entityUpper === 'PAYMENT') {
    const payment = await prisma.payment.findUnique({
      where: {
        id: entityId,
      },
      select: {
        serviceOrder: {
          select: {
            organizationId: true,
          },
        },
      },
    });

    if (
      payment &&
      payment.serviceOrder.organizationId !== organizationId
    ) {
      throw new ForbiddenError(
        'Payment does not belong to the authenticated organization'
      );
    }

    return;
  }

  if (entityUpper === 'PART') {
    // Parts are currently global in the schema.
    // There is no organizationId on Part.
    return;
  }

  throw new ForbiddenError(
    `Unsupported entity type: ${entityType}`
  );
}

/**
 * P0.3 + P0.4:
 * Validates that CUSTOMER can manipulate only entities
 * belonging to their own Customer identity.
 */
async function validateCustomerOwnership(
  entityType: string,
  entityId: string,
  payload: Record<string, any>,
  authenticatedCustomerId: string
): Promise<void> {
  const entityUpper = entityType.toUpperCase();

  if (entityUpper === 'CUSTOMER') {
    if (entityId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer'
      );
    }

    return;
  }

  if (entityUpper === 'EQUIPMENT') {
    const equipment = await prisma.equipment.findUnique({
      where: {
        id: entityId,
      },
    });

    if (
      equipment &&
      equipment.customerId !== authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer equipment'
      );
    }

    const payloadCustomerId =
      payload.customer_id ||
      payload.customerId;

    if (
      payloadCustomerId &&
      payloadCustomerId !== authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot assign Equipment to another Customer'
      );
    }

    return;
  }

  if (entityUpper === 'SERVICE_ORDER') {
    const serviceOrder = await prisma.serviceOrder.findUnique({
      where: {
        id: entityId,
      },
    });

    if (
      serviceOrder &&
      serviceOrder.customerId !== authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer Service Order'
      );
    }

    const payloadCustomerId =
      payload.customer_id ||
      payload.customerId;

    if (
      payloadCustomerId &&
      payloadCustomerId !== authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot assign Service Order to another Customer'
      );
    }

    return;
  }

  if (entityUpper === 'SERVICE_ORDER_ITEM') {
    const item = await prisma.serviceOrderItem.findUnique({
      where: {
        id: entityId,
      },
      include: {
        serviceOrder: {
          select: {
            customerId: true,
          },
        },
      },
    });

    if (
      item &&
      item.serviceOrder.customerId !== authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer Service Order Item'
      );
    }

    return;
  }

  if (entityUpper === 'PAYMENT') {
    const payment = await prisma.payment.findUnique({
      where: {
        id: entityId,
      },
    });

    if (
      payment &&
      payment.customerId !== authenticatedCustomerId
    ) {
      throw new ForbiddenError(
        'CUSTOMER cannot modify another Customer Payment'
      );
    }

    return;
  }

  // CUSTOMER cannot manipulate Parts or unknown entities.
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
  const body = pushSyncSchema.parse(request.body);

  const authUser = getAuthUser(request);
  const authenticatedUserId = authUser.sub;

  let organizationId: string;

  try {
    organizationId = await getAuthenticatedOrganizationId(
      authenticatedUserId,
      authUser.role,
      authUser.customerId
    );
  } catch (error) {
    if (error instanceof ForbiddenError) {
      return reply.status(403).send({
        error: error.message,
      });
    }

    throw error;
  }

  const results: Array<{
    operationId: string;
    status: 'SYNCED' | 'FAILED' | 'CONFLICT';
    error?: string;
  }> = [];

  for (const entry of body.entries) {
    try {
      const currentHash = computePayloadHash(entry.payload);

      /*
       * Organization boundary.
       *
       * IMPORTANT:
       * organizationId comes from the authenticated identity,
       * never from the client payload.
       */
      await validateOrganizationOwnership(
        entry.entityType,
        entry.entityId,
        organizationId
      );

      /*
       * CUSTOMER ownership boundary.
       */
      if (authUser.role === 'CUSTOMER') {
        if (!authUser.customerId) {
          results.push({
            operationId: entry.operationId,
            status: 'FAILED',
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

      /*
       * Idempotency reservation.
       */
      const idempotencyResult =
        await reserveIdempotencySlot(
          entry.operationId,
          currentHash,
          authenticatedUserId,
          entry.deviceId
        );

      if (!idempotencyResult.isNew) {
        if (idempotencyResult.conflict) {
          results.push({
            operationId: entry.operationId,
            status: 'CONFLICT',
            error:
              'IDEMPOTENCY_KEY_REUSE: Operation ID was reused with a different payload',
          });

          continue;
        }

        results.push({
          operationId: entry.operationId,
          status: 'SYNCED',
        });

        continue;
      }

      /*
       * Process operation atomically.
       */
      await prisma.$transaction(async (tx) => {
        const entityUpper =
          entry.entityType.toUpperCase();

        /*
         * CUSTOMER
         */
        if (entityUpper === 'CUSTOMER') {
          if (
            entry.operationType === 'CREATE' ||
            entry.operationType === 'UPDATE'
          ) {
            await tx.customer.upsert({
              where: {
                id: entry.entityId,
              },

              create: {
                id: entry.entityId,
                name: entry.payload.name,
                document:
                  entry.payload.document || null,
                email:
                  entry.payload.email || null,
                phone:
                  entry.payload.phone || null,
                address:
                  entry.payload.address || null,
              },

              update: {
                name: entry.payload.name,
                document:
                  entry.payload.document || null,
                email:
                  entry.payload.email || null,
                phone:
                  entry.payload.phone || null,
                address:
                  entry.payload.address || null,
              },
            });

            /*
             * Ensure the Customer is associated with
             * the authenticated organization.
             */
            await tx.customerOrganization.upsert({
              where: {
                customerId_organizationId: {
                  customerId: entry.entityId,
                  organizationId,
                },
              },

              create: {
                customerId: entry.entityId,
                organizationId,
                status: 'ACTIVE',
              },

              update: {},
            });
          } else if (
            entry.operationType === 'DELETE'
          ) {
            await tx.customerOrganization
              .delete({
                where: {
                  customerId_organizationId: {
                    customerId: entry.entityId,
                    organizationId,
                  },
                },
              })
              .catch(() => null);
          }
        }

        /*
         * EQUIPMENT
         */
        else if (entityUpper === 'EQUIPMENT') {
          if (
            entry.operationType === 'CREATE' ||
            entry.operationType === 'UPDATE'
          ) {
            const customerId =
              entry.payload.customer_id ||
              entry.payload.customerId;

            if (!customerId) {
              throw new Error(
                'EQUIPMENT requires customerId'
              );
            }

            const customerRelation =
              await tx.customerOrganization.findUnique({
                where: {
                  customerId_organizationId: {
                    customerId,
                    organizationId,
                  },
                },
              });

            if (!customerRelation) {
              throw new ForbiddenError(
                'Equipment customer does not belong to the authenticated organization'
              );
            }

            await tx.equipment.upsert({
              where: {
                id: entry.entityId,
              },

              create: {
                id: entry.entityId,
                customerId,
                type: entry.payload.type,
                brand: entry.payload.brand,
                model: entry.payload.model,
                serialNumber:
                  entry.payload.serial_number ||
                  entry.payload.serialNumber ||
                  null,
                notes:
                  entry.payload.notes || null,
              },

              update: {
                type: entry.payload.type,
                brand: entry.payload.brand,
                model: entry.payload.model,
                serialNumber:
                  entry.payload.serial_number ||
                  entry.payload.serialNumber ||
                  null,
                notes:
                  entry.payload.notes || null,
              },
            });
          } else if (
            entry.operationType === 'DELETE'
          ) {
            await tx.equipment
              .delete({
                where: {
                  id: entry.entityId,
                },
              })
              .catch(() => null);
          }
        }

        /*
         * SERVICE ORDER
         */
        else if (entityUpper === 'SERVICE_ORDER') {
          if (
            entry.operationType === 'CREATE' ||
            entry.operationType === 'UPDATE'
          ) {
            const existingOS =
              await tx.serviceOrder.findUnique({
                where: {
                  id: entry.entityId,
                },
              });

            const newStatus =
              (entry.payload.status as ServiceOrderStatus) ||
              ServiceOrderStatus.DIAGNOSTICO;

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
              entry.payload.customer_id ||
              entry.payload.customerId;

            const equipmentId =
              entry.payload.equipment_id ||
              entry.payload.equipmentId;

            const technicianId =
              entry.payload.technician_id ||
              entry.payload.technicianId ||
              null;

            const problemDescription =
              entry.payload.problem_description ||
              entry.payload.problemDescription;

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

            if (!problemDescription) {
              throw new Error(
                'SERVICE_ORDER requires problemDescription'
              );
            }

            /*
             * Customer must belong to organization.
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

            if (!customerRelation) {
              throw new ForbiddenError(
                'Service Order customer does not belong to the authenticated organization'
              );
            }

            /*
             * Equipment must belong to the specified customer.
             */
            const equipment =
              await tx.equipment.findFirst({
                where: {
                  id: equipmentId,
                  customerId,
                },
              });

            if (!equipment) {
              throw new Error(
                'Equipment does not belong to the specified customer'
              );
            }

            await tx.serviceOrder.upsert({
              where: {
                id: entry.entityId,
              },

              create: {
                id: entry.entityId,
                organizationId,
                customerId,
                equipmentId,
                technicianId,
                status: newStatus,
                problemDescription,
                diagnosis:
                  entry.payload.diagnosis ||
                  null,
                solution:
                  entry.payload.solution ||
                  null,
                totalAmount:
                  entry.payload.total_amount ||
                  entry.payload.totalAmount ||
                  0,
              },

              update: {
                status: newStatus,
                diagnosis:
                  entry.payload.diagnosis ||
                  null,
                solution:
                  entry.payload.solution ||
                  null,
                totalAmount:
                  entry.payload.total_amount ||
                  entry.payload.totalAmount ||
                  0,
              },
            });
          } else if (
            entry.operationType === 'DELETE'
          ) {
            await tx.serviceOrder
              .delete({
                where: {
                  id: entry.entityId,
                },
              })
              .catch(() => null);
          }
        }

        /*
         * PART
         *
         * Parts are currently global because the schema
         * does not contain organizationId on Part.
         */
        else if (entityUpper === 'PART') {
          if (
            entry.operationType === 'CREATE' ||
            entry.operationType === 'UPDATE'
          ) {
            await tx.part.upsert({
              where: {
                id: entry.entityId,
              },

              create: {
                id: entry.entityId,
                name: entry.payload.name,
                sku: entry.payload.sku,
                price: entry.payload.price,
                costPrice:
                  entry.payload.cost_price ||
                  entry.payload.costPrice ||
                  0,
                stockQuantity:
                  entry.payload.stock_quantity ||
                  entry.payload.stockQuantity ||
                  0,
              },

              update: {
                name: entry.payload.name,
                sku: entry.payload.sku,
                price: entry.payload.price,
                costPrice:
                  entry.payload.cost_price ||
                  entry.payload.costPrice ||
                  0,
                stockQuantity:
                  entry.payload.stock_quantity ||
                  entry.payload.stockQuantity ||
                  0,
              },
            });
          } else if (
            entry.operationType === 'DELETE'
          ) {
            await tx.part
              .delete({
                where: {
                  id: entry.entityId,
                },
              })
              .catch(() => null);
          }
        }

        /*
         * SERVICE ORDER ITEM
         */
        else if (
          entityUpper === 'SERVICE_ORDER_ITEM'
        ) {
          if (
            entry.operationType === 'CREATE' ||
            entry.operationType === 'UPDATE'
          ) {
            const serviceOrderId =
              entry.payload.service_order_id ||
              entry.payload.serviceOrderId;

            if (!serviceOrderId) {
              throw new Error(
                'SERVICE_ORDER_ITEM requires serviceOrderId'
              );
            }

            const serviceOrder =
              await tx.serviceOrder.findUnique({
                where: {
                  id: serviceOrderId,
                },
                select: {
                  organizationId: true,
                },
              });

            if (!serviceOrder) {
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

            await tx.serviceOrderItem.upsert({
              where: {
                id: entry.entityId,
              },

              create: {
                id: entry.entityId,
                serviceOrderId,
                partId:
                  entry.payload.part_id ||
                  entry.payload.partId ||
                  null,
                description:
                  entry.payload.description,
                quantity:
                  entry.payload.quantity || 1,
                unitPrice:
                  entry.payload.unit_price ||
                  entry.payload.unitPrice ||
                  0,
                totalPrice:
                  entry.payload.total_price ||
                  entry.payload.totalPrice ||
                  0,
              },

              update: {
                description:
                  entry.payload.description,
                quantity:
                  entry.payload.quantity || 1,
                unitPrice:
                  entry.payload.unit_price ||
                  entry.payload.unitPrice ||
                  0,
                totalPrice:
                  entry.payload.total_price ||
                  entry.payload.totalPrice ||
                  0,
              },
            });
          } else if (
            entry.operationType === 'DELETE'
          ) {
            await tx.serviceOrderItem
              .delete({
                where: {
                  id: entry.entityId,
                },
              })
              .catch(() => null);
          }
        }

        else {
          throw new Error(
            `Unsupported entity type: ${entry.entityType}`
          );
        }

        /*
         * Sync Change Log
         */
        const changeLog =
          await tx.syncChangeLog.create({
            data: {
              cursor: entry.operationId,
              entityType: entry.entityType,
              entityId: entry.entityId,
              operationType: entry.operationType,
              data: entry.payload,
            },
          });

        await tx.syncChangeLog.update({
          where: {
            id: changeLog.id,
          },
          data: {
            cursor: changeLog.id.toString(),
          },
        });
      });

      /*
       * Update idempotency result after successful transaction.
       */
      await prisma.operationIdempotency
        .update({
          where: {
            operationId: entry.operationId,
          },
          data: {
            responseBody: {
              status: 'SYNCED',
            },
            responseStatus: 200,
          },
        })
        .catch(() => { });

      results.push({
        operationId: entry.operationId,
        status: 'SYNCED',
      });
    } catch (err: any) {
      results.push({
        operationId: entry.operationId,
        status:
          err?.statusCode === 403
            ? 'FAILED'
            : 'FAILED',
        error:
          err?.message ||
          'Unknown processing error',
      });
    }
  }

  return reply.status(200).send({
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
    pullSyncQuerySchema.parse(request.query);

  const authUser = getAuthUser(request);

  let cursorId = 0n;

  if (query.cursor) {
    try {
      cursorId = BigInt(query.cursor);
    } catch {
      cursorId = 0n;
    }
  }

  const baseWhere =
    cursorId > 0n
      ? {
        id: {
          gt: cursorId,
        },
      }
      : {};

  const organizationId =
    await getAuthenticatedOrganizationId(
      authUser.sub,
      authUser.role,
      authUser.customerId
    );

  let authorizedEntityIds: Set<string>;

  if (authUser.role === 'CUSTOMER') {
    /*
     * CUSTOMER:
     * only own Customer, Equipment, Service Orders,
     * Service Order Items and Payments.
     */
    const customerId = authUser.customerId;

    if (!customerId) {
      return reply.status(403).send({
        error:
          'CUSTOMER user has no associated Customer identity',
      });
    }

    const [
      equipments,
      serviceOrders,
      payments,
    ] = await Promise.all([
      prisma.equipment.findMany({
        where: {
          customerId,
        },
        select: {
          id: true,
        },
      }),

      prisma.serviceOrder.findMany({
        where: {
          customerId,
          organizationId,
        },
        select: {
          id: true,
        },
      }),

      prisma.payment.findMany({
        where: {
          customerId,
          serviceOrder: {
            organizationId,
          },
        },
        select: {
          id: true,
        },
      }),
    ]);

    const serviceOrderIds =
      serviceOrders.map(
        (order) => order.id
      );

    const serviceOrderItems =
      serviceOrderIds.length > 0
        ? await prisma.serviceOrderItem.findMany({
          where: {
            serviceOrderId: {
              in: serviceOrderIds,
            },
          },
          select: {
            id: true,
          },
        })
        : [];

    authorizedEntityIds =
      new Set<string>([
        customerId,

        ...equipments.map(
          (equipment) => equipment.id
        ),

        ...serviceOrderIds,

        ...serviceOrderItems.map(
          (item) => item.id
        ),

        ...payments.map(
          (payment) => payment.id
        ),
      ]);
  } else {
    /*
     * ADMIN / TECHNICIAN:
     * only entities belonging to their organization.
     */
    const [
      customerRelations,
      equipments,
      serviceOrders,
      payments,
    ] = await Promise.all([
      prisma.customerOrganization.findMany({
        where: {
          organizationId,
          status: 'ACTIVE',
        },
        select: {
          customerId: true,
        },
      }),

      prisma.equipment.findMany({
        where: {
          customer: {
            organizations: {
              some: {
                organizationId,
                status: 'ACTIVE',
              },
            },
          },
        },
        select: {
          id: true,
        },
      }),

      prisma.serviceOrder.findMany({
        where: {
          organizationId,
        },
        select: {
          id: true,
        },
      }),

      prisma.payment.findMany({
        where: {
          serviceOrder: {
            organizationId,
          },
        },
        select: {
          id: true,
        },
      }),
    ]);

    const customerIds =
      customerRelations.map(
        (relation) => relation.customerId
      );

    const equipmentIds =
      equipments.map(
        (equipment) => equipment.id
      );

    const serviceOrderIds =
      serviceOrders.map(
        (order) => order.id
      );

    const paymentIds =
      payments.map(
        (payment) => payment.id
      );

    const serviceOrderItems =
      serviceOrderIds.length > 0
        ? await prisma.serviceOrderItem.findMany({
          where: {
            serviceOrderId: {
              in: serviceOrderIds,
            },
          },
          select: {
            id: true,
          },
        })
        : [];

    authorizedEntityIds =
      new Set<string>([
        ...customerIds,
        ...equipmentIds,
        ...serviceOrderIds,
        ...serviceOrderItems.map(
          (item) => item.id
        ),
        ...paymentIds,
      ]);
  }

  /*
   * Fetch changes.
   */
  const allChanges =
    await prisma.syncChangeLog.findMany({
      where: baseWhere,
      orderBy: {
        id: 'asc',
      },
      take: query.limit,
    });

  const changes =
    allChanges.filter((change) =>
      authorizedEntityIds.has(
        change.entityId
      )
    );

  const nextCursor =
    changes.length > 0
      ? changes[
        changes.length - 1
      ].id.toString()
      : query.cursor || '0';

  return reply.status(200).send({
    nextCursor,

    changes: changes.map((change) => ({
      cursor: change.id.toString(),
      entityType: change.entityType,
      entityId: change.entityId,
      operationType: change.operationType,
      data: change.data,
      createdAt: change.createdAt,
    })),
  });
}