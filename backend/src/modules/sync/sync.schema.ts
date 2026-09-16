import { ServiceOrderStatus } from '@prisma/client';
import { z } from 'zod';
import { legacyMoneyToMinor, quantitySchema, serviceOrderMoneyMinorSchema } from '../../core/money/money.js';

export const revisionSchema = z.string().regex(/^(0|[1-9][0-9]*)$/).max(20);
export const outboxEntrySchema = z.object({
  operationId: z.string().uuid(), deviceId: z.string().max(200).optional(), userId: z.string().max(200).optional(),
  entityType: z.string().min(1).max(64), entityId: z.string().uuid(),
  operationType: z.enum(['CREATE', 'UPDATE', 'DELETE']), payload: z.record(z.unknown()),
  createdAt: z.string().max(64),
}).strict();
export const pushSyncSchema = z.object({
  contractVersion: z.union([z.literal(1), z.literal(2)]).default(1),
  entries: z.array(outboxEntrySchema).min(1).max(100),
}).strict();
export const pullSyncQuerySchema = z.object({
  contractVersion: z.coerce.number().pipe(z.union([z.literal(1), z.literal(2)])).default(1),
  cursor: revisionSchema.optional(), limit: z.coerce.number().int().min(1).max(100).default(50),
}).strict();
export const bootstrapSchema = z.object({
  contractVersion: z.literal(2), continuationToken: z.string().max(200).optional(),
  limit: z.number().int().min(1).max(100).default(50),
}).strict();

const uuid = z.string().uuid();
const optionalText = z.string().max(10000).nullable().optional();
const itemFields = {
  serviceOrderId: uuid, partId: uuid.nullable().optional(),
  description: z.string().min(1).max(1000), quantity: quantitySchema, unitPriceMinor: serviceOrderMoneyMinorSchema,
};
const orderFields = {
  customerId: uuid, equipmentId: uuid, technicianId: uuid.nullable().optional(),
  problemDescription: z.string().min(1).max(10000), diagnosis: optionalText, solution: optionalText,
  status: z.nativeEnum(ServiceOrderStatus).optional(),
};
const schemas = {
  SERVICE_ORDER: {
    CREATE: z.object(orderFields).strict(), UPDATE: z.object(orderFields).partial().strict(), DELETE: z.object({}).strict(),
  },
  SERVICE_ORDER_ITEM: {
    CREATE: z.object(itemFields).strict(), UPDATE: z.object(itemFields).partial().strict(),
    DELETE: z.object({ serviceOrderId: uuid.optional() }).strict(),
  },
};
const aliases: Record<string, string> = {
  service_order_id: 'serviceOrderId', part_id: 'partId', customer_id: 'customerId', equipment_id: 'equipmentId',
  technician_id: 'technicianId', problem_description: 'problemDescription', unit_price: 'unitPrice',
  total_price: 'totalPrice', total_amount: 'totalAmount', organization_id: 'organizationId',
  created_at: 'createdAt', updated_at: 'updatedAt',
};
export type MoneyAssertions = { totalAmountMinor?: number; totalPriceMinor?: number; organizationId?: string };
export type NormalizedEntry = Omit<OutboxEntry, 'payload'> & { payload: Record<string, any>; assertions: MoneyAssertions };

/** Strict entity/operation validation applies BEFORE money reaches persistence.
 * V1 differences are limited to spelling and representation, not authority. */
export function normalizeSyncEntry(entry: OutboxEntry, contractVersion: 1 | 2): NormalizedEntry {
  const entityType = entry.entityType.toUpperCase();
  if (!(entityType in schemas)) return { ...entry, entityType, assertions: {}, payload: entry.payload };
  const payload: Record<string, unknown> = { ...entry.payload };
  const assertions: MoneyAssertions = {};
  if (contractVersion === 1) {
    for (const [alias, canonical] of Object.entries(aliases)) if (Object.hasOwn(payload, alias)) {
      if (Object.hasOwn(payload, canonical)) throw new RangeError('SYNC_PAYLOAD_ALIAS_AMBIGUOUS');
      payload[canonical] = payload[alias]; delete payload[alias];
    }
    if (Object.hasOwn(payload, 'unitPrice')) {
      if (Object.hasOwn(payload, 'unitPriceMinor')) throw new RangeError('SYNC_MONEY_AMBIGUOUS');
      payload.unitPriceMinor = legacyMoneyToMinor(payload.unitPrice); delete payload.unitPrice;
    } else if (Object.hasOwn(payload, 'unitPriceMinor')) {
      throw new RangeError('SYNC_V1_MINOR_FIELD_FORBIDDEN');
    }
    for (const [field, target] of [['totalAmount', 'totalAmountMinor'], ['totalPrice', 'totalPriceMinor']] as const) {
      if (Object.hasOwn(payload, target)) throw new RangeError('SYNC_DERIVED_MONEY_FORBIDDEN');
      if (Object.hasOwn(payload, field)) {
        if ((entityType === 'SERVICE_ORDER') !== (field === 'totalAmount')) throw new RangeError('SYNC_MONEY_FIELD_INVALID');
        assertions[target] = legacyMoneyToMinor(payload[field]); delete payload[field];
      }
    }
    if (payload.id !== undefined && payload.id !== entry.entityId) throw new RangeError('SYNC_ENTITY_ID_MISMATCH');
    if (payload.organizationId !== undefined) assertions.organizationId = uuid.parse(payload.organizationId);
    for (const key of ['id', 'organizationId', 'createdAt', 'updatedAt']) delete payload[key];
    // An old local row may echo this internal field. It is never interpreted.
    if (Object.hasOwn(payload, 'financeCoreVersion')) throw new RangeError('SYNC_SERVER_OWNED_FIELD');
  }
  const schema = schemas[entityType as keyof typeof schemas][entry.operationType];
  return { ...entry, entityType, payload: schema.parse(payload), assertions };
}
export type OutboxEntry = z.infer<typeof outboxEntrySchema>;
export type PushSyncInput = z.infer<typeof pushSyncSchema>;
export type PullSyncQuery = z.infer<typeof pullSyncQuerySchema>;
