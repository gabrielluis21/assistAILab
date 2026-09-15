import { decimalToMinorUnits, DECIMAL_10_2_MAX_MINOR } from '../money/money.js';
import { syncMac } from '../sync/sync_integrity.js';
import { Prisma } from '@prisma/client';
import { randomUUID } from 'node:crypto';
import { prisma } from './prisma.js';

// One existing-table row serializes projected writes BEFORE any domain locks or
// auto-increment allocation. No DDL, timestamp clock or connection-scoped lock.
const BARRIER_CURSOR = '__FE02B_PROJECTION_BARRIER__';
const managedTransactions = new WeakSet<object>();
export const isSyncTransaction = (db: object): boolean => managedTransactions.has(db);

export async function lockSyncProjection(tx: Prisma.TransactionClient): Promise<void> {
  await tx.$executeRaw`INSERT INTO sync_change_logs
    (cursor, entityType, entityId, operationType, data, createdAt)
    VALUES (${BARRIER_CURSOR}, '__SYNC_BARRIER__', '__SYNC_BARRIER__', 'UPDATE', '{}', NOW(3)) ON DUPLICATE KEY UPDATE cursor = ${BARRIER_CURSOR}`;
  await tx.$queryRaw`SELECT id FROM sync_change_logs WHERE cursor = ${BARRIER_CURSOR} FOR UPDATE`;
}

export async function projectionHighWater(tx: Prisma.TransactionClient): Promise<string> {
  const last = await tx.syncChangeLog.findFirst({ orderBy: { id: 'desc' }, select: { id: true } });
  return (last?.id ?? 0n).toString();
}

export type SyncAudience = { organizationIds: string[]; customerIds: string[] };
const models = {
  customer: 'CUSTOMER', equipment: 'EQUIPMENT', serviceOrder: 'SERVICE_ORDER',
  serviceOrderItem: 'SERVICE_ORDER_ITEM', customerOrganization: 'CUSTOMER',
} as const;
type ObservedModel = keyof typeof models;
const mutationMethods = new Set(['create', 'update', 'upsert', 'delete', 'updateMany', 'deleteMany']);

async function audience(tx: Prisma.TransactionClient, model: ObservedModel, row: any): Promise<SyncAudience> {
  if (model === 'customerOrganization') return { organizationIds: [row.organizationId], customerIds: [row.customerId] };
  if (model === 'customer') {
    const relations = await tx.customerOrganization.findMany({ where: { customerId: row.id }, select: { organizationId: true } });
    return { organizationIds: relations.map(r => r.organizationId), customerIds: [row.id] };
  }
  if (model === 'equipment') {
    const orders = await tx.serviceOrder.findMany({ where: { equipmentId: row.id }, select: { organizationId: true } });
    return { organizationIds: [...new Set([...orders.map(o => o.organizationId), ...(row.organizationId ? [row.organizationId] : [])])],
      customerIds: row.ownerType === 'CUSTOMER' && row.customerId ? [row.customerId] : [] };
  }
  const order = model === 'serviceOrder' ? row : await tx.serviceOrder.findUniqueOrThrow({ where: { id: row.serviceOrderId } });
  return { organizationIds: [order.organizationId], customerIds: [order.customerId] };
}

async function appendChange(tx: Prisma.TransactionClient, model: ObservedModel, row: any,
  operationType: 'CREATE' | 'UPDATE' | 'DELETE', recipients: SyncAudience): Promise<void> {
  const data = {
    ...(model === 'serviceOrder' ? {
      id: row.id, status: row.status, organizationId: row.organizationId, customerId: row.customerId,
      equipmentId: row.equipmentId, technicianId: row.technicianId, problemDescription: row.problemDescription,
      diagnosis: row.diagnosis, solution: row.solution,
      totalAmountMinor: decimalToMinorUnits(row.totalAmount, DECIMAL_10_2_MAX_MINOR),
    } : {}),
    syncMetadataVersion: 2,
    audience: recipients,
    parentId: model === 'serviceOrderItem' ? row.serviceOrderId : null,
    // A detached CustomerOrganization invalidates this tenant's Customer view.
    relationshipChange: model === 'customerOrganization',
  };
  const change = await tx.syncChangeLog.create({ data: {
    cursor: `pending:${randomUUID()}`, entityType: models[model],
    entityId: model === 'customerOrganization' ? row.customerId : row.id, operationType, data,
  } });
  await tx.syncChangeLog.update({ where: { id: change.id }, data: { cursor: change.id.toString(), data: { ...data, metadataMac: syncMac('change-metadata', { id: change.id.toString(), entityType: change.entityType, entityId: change.entityId, operationType: change.operationType, data }) } } });
}

/** Only the explicit transaction boundary observes projection writes. Reads and
 * non-projected delegates retain Prisma semantics. Metadata comes from DB rows,
 * never from a Sync payload. Batch deletions retain each original audience. */
type PendingServiceOrderChange = {
  initialRow?: any;
  recipients: SyncAudience;
};

function mergeAudience(current: SyncAudience, next: SyncAudience): SyncAudience {
  return {
    organizationIds: [...new Set([...current.organizationIds, ...next.organizationIds])],
    customerIds: [...new Set([...current.customerIds, ...next.customerIds])],
  };
}

function observeProjectionWrites(tx: Prisma.TransactionClient): {
  client: Prisma.TransactionClient;
  flushServiceOrderChanges: () => Promise<void>;
} {
  const delegates = new Map<string, object>();
  const pendingServiceOrders = new Map<string, PendingServiceOrderChange>();
  const wrapped = new Proxy(tx, {
    get(target, key, receiver) {
      if (typeof key !== 'string' || !(key in models)) return Reflect.get(target, key, receiver);
      if (delegates.has(key)) return delegates.get(key);
      const model = key as ObservedModel;
      const delegate = (target as any)[model];
      const proxy = new Proxy(delegate, { get(source, method) {
        if (typeof method !== 'string' || !mutationMethods.has(method)) return Reflect.get(source, method);
        return async (args: any) => {
          // Unique selectors are also valid findUnique filters; findMany uses
          // ordinary WhereInput. Resolve compound unique selectors explicitly.
          const where = args.where;
          const previous = method === 'create' ? [] :
            (method === 'updateMany' || method === 'deleteMany') ? await delegate.findMany({ where }) :
            [await delegate.findUnique({ where })].filter(Boolean);
          const beforeAudience = new Map<string, SyncAudience>();
          for (const row of previous) beforeAudience.set(row.id, await audience(tx, model, row));
          const result = await source[method](args);
          const after = method === 'delete' || method === 'deleteMany' ? [] :
            method === 'updateMany' ? await delegate.findMany({ where: { id: { in: previous.map((r: any) => r.id) } } }) :
            [await delegate.findUniqueOrThrow({ where: { id: result.id ?? previous[0]?.id ?? args.data?.id ?? args.create?.id } })];
          if (model === 'serviceOrder') {
            for (const row of previous) {
              const current = pendingServiceOrders.get(row.id);
              const recipients = beforeAudience.get(row.id)!;
              pendingServiceOrders.set(row.id, {
                initialRow: current ? current.initialRow : row,
                recipients: current ? mergeAudience(current.recipients, recipients) : recipients,
              });
            }
            for (const row of after) {
              const current = pendingServiceOrders.get(row.id);
              const nextAudience = await audience(tx, model, row);
              pendingServiceOrders.set(row.id, {
                initialRow: current?.initialRow,
                recipients: current ? mergeAudience(current.recipients, nextAudience) : nextAudience,
              });
            }
            return result;
          }
          for (const row of after) {
            const nextAudience = await audience(tx, model, row);
            const priorAudience = beforeAudience.get(row.id);
            const recipients = {
              organizationIds: [...new Set([...(priorAudience?.organizationIds ?? []), ...nextAudience.organizationIds])],
              customerIds: [...new Set([...(priorAudience?.customerIds ?? []), ...nextAudience.customerIds])],
            };
            await appendChange(tx, model, row, priorAudience ? 'UPDATE' : 'CREATE', recipients);
          }
          for (const row of previous) if (!after.some((r: any) => r.id === row.id)) {
            await appendChange(tx, model, row, 'DELETE', beforeAudience.get(row.id)!);
          }
          return result;
        };
      } });
      delegates.set(key, proxy);
      return proxy;
    },
  });
  managedTransactions.add(wrapped);
  return {
    client: wrapped,
    flushServiceOrderChanges: async () => {
      for (const [id, pending] of pendingServiceOrders) {
        const finalRow = await tx.serviceOrder.findUnique({ where: { id } });
        if (finalRow) {
          const recipients = mergeAudience(pending.recipients, await audience(tx, 'serviceOrder', finalRow));
          await appendChange(tx, 'serviceOrder', finalRow, pending.initialRow ? 'UPDATE' : 'CREATE', recipients);
        } else if (pending.initialRow) {
          await appendChange(tx, 'serviceOrder', pending.initialRow, 'DELETE', pending.recipients);
        }
      }
    },
  };
}

type Options = { maxWait?: number; timeout?: number; isolationLevel?: Prisma.TransactionIsolationLevel };
export function syncTransaction<T>(work: (tx: Prisma.TransactionClient) => Promise<T>, options: Options = {}): Promise<T> {
  return prisma.$transaction(async tx => {
    await lockSyncProjection(tx);
    const observed = observeProjectionWrites(tx);
    const result = await work(observed.client);
    await observed.flushServiceOrderChanges();
    return result;
  }, { maxWait: 10_000, timeout: 30_000, ...options, isolationLevel: Prisma.TransactionIsolationLevel.ReadCommitted });
}

/** The same barrier prevents a later commit with id <= H, and keeps the entire
 * authorized snapshot and its revision in one consistent cut. */
export function syncRead<T>(work: (tx: Prisma.TransactionClient, revision: string) => Promise<T>): Promise<T> {
  return prisma.$transaction(async tx => {
    await lockSyncProjection(tx);
    return work(tx, await projectionHighWater(tx));
  }, { maxWait: 10_000, timeout: 30_000, isolationLevel: Prisma.TransactionIsolationLevel.ReadCommitted });
}
