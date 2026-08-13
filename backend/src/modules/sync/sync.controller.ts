import { FastifyRequest, FastifyReply } from 'fastify';
import { ServiceOrderStatus } from '@prisma/client';
import { prisma } from '../../core/database/prisma.js';
import { pushSyncSchema, pullSyncQuerySchema } from './sync.schema.js';
import { computePayloadHash } from '../../core/middleware/idempotency.middleware.js';
import { isValidStatusTransition } from '../service_orders/service_order_state_machine.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ForbiddenError } from '../../core/utils/errors.js';

/**
 * P0.5: Atomically reserve an idempotency slot by attempting a DB insert.
 * Returns: { isNew: true } if the operation is genuinely new.
 * Returns: { isNew: false, existing } if a duplicate was found.
 * Returns: { isNew: false, conflict: true } if same key with different hash.
 */
async function reserveIdempotencySlot(
  operationId: string,
  currentHash: string,
  userId: string,
  deviceId?: string
): Promise<{ isNew: true } | { isNew: false; conflict: boolean; responseBody?: any }> {
  try {
    await prisma.operationIdempotency.create({
      data: {
        operationId,
        endpoint: '/api/v1/sync/push',
        requestHash: currentHash,
        responseStatus: 200,
        responseBody: {}, // placeholder — updated after processing
        userId,
        deviceId: deviceId ?? null,
      },
    });
    return { isNew: true };
  } catch (err: any) {
    // P2002 = Unique constraint violation — operation already exists
    if (err?.code === 'P2002') {
      const existing = await prisma.operationIdempotency.findUnique({
        where: { operationId },
      });
      if (!existing) {
        // Very rare race: record was deleted between create and findUnique
        return { isNew: true };
      }
      if (existing.requestHash !== currentHash) {
        return { isNew: false, conflict: true };
      }
      return { isNew: false, conflict: false, responseBody: existing.responseBody };
    }
    throw err;
  }
}

/**
 * P0.3 + P0.4: Validates that a CUSTOMER user is authorized to push changes for the given entity.
 * Uses the authenticated JWT identity (req.user.customerId) — never trusts entry.userId or payload.
 */
async function validateCustomerOwnership(
  entityType: string,
  entityId: string,
  payload: Record<string, any>,
  authenticatedCustomerId: string
): Promise<void> {
  const entityUpper = entityType.toUpperCase();

  if (entityUpper === 'CUSTOMER') {
    // A CUSTOMER can only push changes to their own Customer record
    if (entityId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        `P0.3: CUSTOMER cannot push changes to Customer ${entityId} — not owner`
      );
    }
  } else if (entityUpper === 'EQUIPMENT') {
    const equipment = await prisma.equipment.findUnique({ where: { id: entityId } });
    if (equipment && equipment.customerId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        `P0.3: CUSTOMER cannot push changes to Equipment ${entityId} — not owner`
      );
    }
    // Also validate customerId in payload if provided
    const payloadCustomerId = payload.customer_id || payload.customerId;
    if (payloadCustomerId && payloadCustomerId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        'P0.3: CUSTOMER cannot assign Equipment to a different Customer'
      );
    }
  } else if (entityUpper === 'SERVICE_ORDER') {
    const so = await prisma.serviceOrder.findUnique({ where: { id: entityId } });
    if (so && so.customerId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        `P0.3: CUSTOMER cannot push changes to Service Order ${entityId} — not owner`
      );
    }
  } else if (entityUpper === 'SERVICE_ORDER_ITEM') {
    const item = await prisma.serviceOrderItem.findUnique({
      where: { id: entityId },
      include: { serviceOrder: { select: { customerId: true } } },
    });
    if (item && item.serviceOrder.customerId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        `P0.3: CUSTOMER cannot push changes to Service Order Item ${entityId} — not owner`
      );
    }
  } else if (entityUpper === 'PAYMENT') {
    const payment = await prisma.payment.findUnique({ where: { id: entityId } });
    if (payment && payment.customerId !== authenticatedCustomerId) {
      throw new ForbiddenError(
        `P0.3: CUSTOMER cannot push changes to Payment ${entityId} — not owner`
      );
    }
  } else {
    // CUSTOMER cannot push to unknown entity types
    throw new ForbiddenError(
      `P0.3: CUSTOMER cannot push changes to entity type ${entityType}`
    );
  }
}

export async function pushSyncHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = pushSyncSchema.parse(request.body);

  // P0.4: Identity comes from the authenticated JWT — never from entry.userId
  const authUser = getAuthUser(request);
  const authenticatedUserId = authUser.sub;

  const results: Array<{ operationId: string; status: 'SYNCED' | 'FAILED' | 'CONFLICT'; error?: string }> = [];

  for (const entry of body.entries) {
    try {
      const currentHash = computePayloadHash(entry.payload);

      // P0.3: If the authenticated user is CUSTOMER, validate ownership before any processing.
      // We do this BEFORE idempotency check to prevent replaying unauthorized operations.
      if (authUser.role === 'CUSTOMER') {
        if (!authUser.customerId) {
          results.push({
            operationId: entry.operationId,
            status: 'FAILED',
            error: 'P0.3: CUSTOMER user has no associated Customer identity',
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

      // P0.5: Atomically reserve the idempotency slot using DB unique constraint.
      // This prevents two simultaneous requests from both processing the same operationId.
      const idempotencyResult = await reserveIdempotencySlot(
        entry.operationId,
        currentHash,
        authenticatedUserId, // P0.4: Always authenticated userId, never entry.userId
        entry.deviceId
      );

      if (!idempotencyResult.isNew) {
        if (idempotencyResult.conflict) {
          results.push({
            operationId: entry.operationId,
            status: 'FAILED',
            error: 'IDEMPOTENCY_KEY_REUSE: Operation ID was reused with a different payload',
          });
          continue;
        }
        // Duplicate with same payload — idempotent response
        results.push({ operationId: entry.operationId, status: 'SYNCED' });
        continue;
      }

      // Process operation within a transaction
      await prisma.$transaction(async (tx) => {
        const entityUpper = entry.entityType.toUpperCase();

        if (entityUpper === 'CUSTOMER') {
          if (entry.operationType === 'CREATE' || entry.operationType === 'UPDATE') {
            await tx.customer.upsert({
              where: { id: entry.entityId },
              create: {
                id: entry.entityId,
                name: entry.payload.name,
                document: entry.payload.document || null,
                email: entry.payload.email || null,
                phone: entry.payload.phone || null,
                address: entry.payload.address || null,
              },
              update: {
                name: entry.payload.name,
                document: entry.payload.document || null,
                email: entry.payload.email || null,
                phone: entry.payload.phone || null,
                address: entry.payload.address || null,
              },
            });
          } else if (entry.operationType === 'DELETE') {
            await tx.customer.delete({ where: { id: entry.entityId } }).catch(() => null);
          }
        } else if (entityUpper === 'EQUIPMENT') {
          if (entry.operationType === 'CREATE' || entry.operationType === 'UPDATE') {
            await tx.equipment.upsert({
              where: { id: entry.entityId },
              create: {
                id: entry.entityId,
                customerId: entry.payload.customer_id || entry.payload.customerId,
                type: entry.payload.type,
                brand: entry.payload.brand,
                model: entry.payload.model,
                serialNumber: entry.payload.serial_number || entry.payload.serialNumber || null,
                notes: entry.payload.notes || null,
              },
              update: {
                type: entry.payload.type,
                brand: entry.payload.brand,
                model: entry.payload.model,
                serialNumber: entry.payload.serial_number || entry.payload.serialNumber || null,
                notes: entry.payload.notes || null,
              },
            });
          } else if (entry.operationType === 'DELETE') {
            await tx.equipment.delete({ where: { id: entry.entityId } }).catch(() => null);
          }
        } else if (entityUpper === 'SERVICE_ORDER') {
          if (entry.operationType === 'CREATE' || entry.operationType === 'UPDATE') {
            const existingOS = await tx.serviceOrder.findUnique({ where: { id: entry.entityId } });
            const newStatus = (entry.payload.status as ServiceOrderStatus) || 'DIAGNOSTICO';
            if (existingOS && !isValidStatusTransition(existingOS.status, newStatus)) {
              throw new Error(`CONFLICT: Invalid status transition from ${existingOS.status} to ${newStatus}`);
            }

            await tx.serviceOrder.upsert({
              where: { id: entry.entityId },
              create: {
                id: entry.entityId,
                customerId: entry.payload.customer_id || entry.payload.customerId,
                equipmentId: entry.payload.equipment_id || entry.payload.equipmentId,
                technicianId: entry.payload.technician_id || entry.payload.technicianId || null,
                status: newStatus,
                problemDescription: entry.payload.problem_description || entry.payload.problemDescription,
                diagnosis: entry.payload.diagnosis || null,
                solution: entry.payload.solution || null,
                totalAmount: entry.payload.total_amount || entry.payload.totalAmount || 0,
              },
              update: {
                status: newStatus,
                diagnosis: entry.payload.diagnosis || null,
                solution: entry.payload.solution || null,
                totalAmount: entry.payload.total_amount || entry.payload.totalAmount,
              },
            });
          } else if (entry.operationType === 'DELETE') {
            await tx.serviceOrder.delete({ where: { id: entry.entityId } }).catch(() => null);
          }
        } else if (entityUpper === 'PART') {
          if (entry.operationType === 'CREATE' || entry.operationType === 'UPDATE') {
            await tx.part.upsert({
              where: { id: entry.entityId },
              create: {
                id: entry.entityId,
                name: entry.payload.name,
                sku: entry.payload.sku,
                price: entry.payload.price,
                costPrice: entry.payload.cost_price || entry.payload.costPrice || 0,
                stockQuantity: entry.payload.stock_quantity || entry.payload.stockQuantity || 0,
              },
              update: {
                name: entry.payload.name,
                sku: entry.payload.sku,
                price: entry.payload.price,
                costPrice: entry.payload.cost_price || entry.payload.costPrice || 0,
                stockQuantity: entry.payload.stock_quantity || entry.payload.stockQuantity || 0,
              },
            });
          } else if (entry.operationType === 'DELETE') {
            await tx.part.delete({ where: { id: entry.entityId } }).catch(() => null);
          }
        } else if (entityUpper === 'SERVICE_ORDER_ITEM') {
          if (entry.operationType === 'CREATE' || entry.operationType === 'UPDATE') {
            await tx.serviceOrderItem.upsert({
              where: { id: entry.entityId },
              create: {
                id: entry.entityId,
                serviceOrderId: entry.payload.service_order_id || entry.payload.serviceOrderId,
                partId: entry.payload.part_id || entry.payload.partId || null,
                description: entry.payload.description,
                quantity: entry.payload.quantity || 1,
                unitPrice: entry.payload.unit_price || entry.payload.unitPrice || 0,
                totalPrice: entry.payload.total_price || entry.payload.totalPrice || 0,
              },
              update: {
                description: entry.payload.description,
                quantity: entry.payload.quantity,
                unitPrice: entry.payload.unit_price || entry.payload.unitPrice,
                totalPrice: entry.payload.total_price || entry.payload.totalPrice,
              },
            });
          } else if (entry.operationType === 'DELETE') {
            await tx.serviceOrderItem.delete({ where: { id: entry.entityId } }).catch(() => null);
          }
        }

        // Register Sync Change Log with monotonic cursor derived from incremental ID
        const changeLog = await tx.syncChangeLog.create({
          data: {
            cursor: entry.operationId, // placeholder unique cursor before acquiring sequence ID
            entityType: entry.entityType,
            entityId: entry.entityId,
            operationType: entry.operationType,
            data: entry.payload,
          },
        });

        // Set cursor to monotonic string representation of BigInt id
        await tx.syncChangeLog.update({
          where: { id: changeLog.id },
          data: { cursor: changeLog.id.toString() },
        });
      });

      // Update the idempotency record with the final response body
      await prisma.operationIdempotency.update({
        where: { operationId: entry.operationId },
        data: { responseBody: { status: 'SYNCED' }, responseStatus: 200 },
      }).catch(() => {});

      results.push({ operationId: entry.operationId, status: 'SYNCED' });
    } catch (err: any) {
      const isForbidden = err?.statusCode === 403;
      results.push({
        operationId: entry.operationId,
        status: isForbidden ? 'FAILED' : 'FAILED',
        error: err?.message || 'Unknown processing error',
      });
    }
  }

  return reply.status(200).send({ results });
}

export async function pullSyncHandler(request: FastifyRequest, reply: FastifyReply) {
  const query = pullSyncQuerySchema.parse(request.query);
  const authUser = getAuthUser(request);

  let cursorId = 0n;
  if (query.cursor) {
    try {
      cursorId = BigInt(query.cursor);
    } catch {
      cursorId = 0n;
    }
  }

  const baseWhere = cursorId > 0n ? { id: { gt: cursorId } } : {};

  let changes;

  if (authUser.role === 'CUSTOMER') {
    // P0.3: CUSTOMER can only receive changes related to their own data.
    // We filter by entityId membership in the CUSTOMER's authorized set.
    const customerId = authUser.customerId;
    if (!customerId) {
      return reply.status(403).send({ error: 'CUSTOMER user has no associated Customer identity' });
    }

    // Gather all entity IDs belonging to this customer
    const [equipments, serviceOrders, payments] = await Promise.all([
      prisma.equipment.findMany({ where: { customerId }, select: { id: true } }),
      prisma.serviceOrder.findMany({ where: { customerId }, select: { id: true } }),
      prisma.payment.findMany({ where: { customerId }, select: { id: true } }),
    ]);

    const soIds = serviceOrders.map((so) => so.id);

    // Include service order items for the customer's service orders
    const soItems = soIds.length > 0
      ? await prisma.serviceOrderItem.findMany({
          where: { serviceOrderId: { in: soIds } },
          select: { id: true },
        })
      : [];

    // Build authorized entity ID set
    const authorizedEntityIds = new Set<string>([
      customerId,
      ...equipments.map((e) => e.id),
      ...soIds,
      ...soItems.map((i) => i.id),
      ...payments.map((p) => p.id),
    ]);

    // P0.3: Filter change log to only entries whose entityId is in the authorized set.
    // This respects entity relationships, not just entityType filtering.
    const allChanges = await prisma.syncChangeLog.findMany({
      where: baseWhere,
      orderBy: { id: 'asc' },
      take: query.limit,
    });

    changes = allChanges.filter((c) => authorizedEntityIds.has(c.entityId));
  } else {
    // ADMIN / TECHNICIAN: full change log access
    changes = await prisma.syncChangeLog.findMany({
      where: baseWhere,
      orderBy: { id: 'asc' },
      take: query.limit,
    });
  }

  const nextCursor = changes.length > 0 ? changes[changes.length - 1].id.toString() : query.cursor || '0';

  return reply.status(200).send({
    nextCursor,
    changes: changes.map((c) => ({
      cursor: c.id.toString(),
      entityType: c.entityType,
      entityId: c.entityId,
      operationType: c.operationType,
      data: c.data,
      createdAt: c.createdAt,
    })),
  });
}

