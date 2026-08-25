import {
  OperationType,
  Prisma,
} from '@prisma/client';

import type {
  ServiceOrder,
} from '@prisma/client';

import {
  randomUUID,
} from 'node:crypto';

import {
  prisma,
} from '../database/prisma.js';

type DatabaseClient =
  | typeof prisma
  | Prisma.TransactionClient;

type ServiceOrderSyncSnapshotSource =
  Pick<
    ServiceOrder,
    | 'id'
    | 'friendlyId'
    | 'organizationId'
    | 'customerId'
    | 'equipmentId'
    | 'technicianId'
    | 'status'
    | 'problemDescription'
    | 'diagnosis'
    | 'solution'
    | 'totalAmount'
    | 'createdAt'
    | 'updatedAt'
  >;

export function toServiceOrderSyncSnapshot(
  order:
    ServiceOrderSyncSnapshotSource
) {
  return {
    id:
      order.id,

    friendlyId:
      order.friendlyId,

    organizationId:
      order.organizationId,

    customerId:
      order.customerId,

    equipmentId:
      order.equipmentId,

    technicianId:
      order.technicianId,

    status:
      order.status,

    problemDescription:
      order.problemDescription,

    diagnosis:
      order.diagnosis,

    solution:
      order.solution,

    totalAmount:
      Number(
        order.totalAmount
      ),

    createdAt:
      order.createdAt
        .toISOString(),

    updatedAt:
      order.updatedAt
        .toISOString(),
  };
}

export async function recordServiceOrderSyncChange(
  order:
    ServiceOrderSyncSnapshotSource,

  operationType:
    OperationType,

  db:
    DatabaseClient = prisma
) {
  const change =
    await db.syncChangeLog
      .create({
        data: {
          cursor:
            `pending:${randomUUID()}`,

          entityType:
            'SERVICE_ORDER',

          entityId:
            order.id,

          operationType,

          data:
            toServiceOrderSyncSnapshot(
              order
            ),
        },
      });

  await db.syncChangeLog
    .update({
      where: {
        id:
          change.id,
      },

      data: {
        cursor:
          change.id
            .toString(),
      },
    });

  return change;
}
