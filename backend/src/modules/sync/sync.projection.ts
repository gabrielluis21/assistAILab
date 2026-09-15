import { serializePayment } from '../payments/payments.service.js';
import { Prisma } from '@prisma/client';
import type { ValidatedPrincipal } from '../../core/auth/live_authority.service.js';
import { resolveLiveAuthority } from '../../core/auth/live_authority.service.js';
import { aggregateTotalMinor, decimalToMinorUnits, decimalMoneyText, lineTotalMinor, DECIMAL_10_2_MAX_MINOR } from '../../core/money/money.js';
import { commercialScopeFingerprint } from '../service_order_finance/commercial_quote_revision.rules.js';
import { approvedQuoteAuthorityFromRevision, liveCommercialScopeFingerprint } from '../service_order_finance/mark_ready.rules.js';
import { ConflictError } from '../../core/utils/errors.js';
import { toServiceOrderSyncSnapshot } from '../../core/sync/sync_change_log.service.js';

export type SyncPrincipal = ValidatedPrincipal;
export function orderScope(principal: SyncPrincipal): Prisma.ServiceOrderWhereInput {
  return principal.role === 'CUSTOMER' ? { customerId: principal.customerId! } : { organizationId: principal.organizationId! };
}
export function customerScope(principal: SyncPrincipal): Prisma.CustomerWhereInput {
  return principal.role === 'CUSTOMER' ? { id: principal.customerId! } : { organizations: { some: { organizationId: principal.organizationId! } } };
}
export function equipmentScope(principal: SyncPrincipal): Prisma.EquipmentWhereInput {
  return principal.role === 'CUSTOMER' ? { customerId: principal.customerId!, ownerType: 'CUSTOMER' } : {
    OR: [ { ownerType: 'ORGANIZATION', organizationId: principal.organizationId! },
      { ownerType: 'CUSTOMER', serviceOrders: { some: { organizationId: principal.organizationId! } } } ],
  };
}

export async function assertSyncPrincipal(tx: Prisma.TransactionClient, principal: SyncPrincipal): Promise<void> {
  // Revalidate on the same transaction snapshot as the mutation/read.
  await resolveLiveAuthority(principal, tx);
}

export type OrderAggregate = Prisma.ServiceOrderGetPayload<{ include: {
  items: true; currentQuoteRevision: true; lastApprovedQuoteRevision: true;
} }>;
export const orderAggregateInclude = {
  items: { orderBy: { id: 'asc' as const } }, currentQuoteRevision: true, lastApprovedQuoteRevision: true,
};

export function commercialProjection(order: OrderAggregate) {
  if ((order.currentQuoteRevisionId ?? null) !== (order.currentQuoteRevision?.id ?? null) ||
      (order.lastApprovedQuoteRevisionId ?? null) !== (order.lastApprovedQuoteRevision?.id ?? null) ||
      (order.lastApprovedQuoteRevisionId && !order.currentQuoteRevisionId)) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
  const items = order.items.map(item => ({
    id: item.id, serviceOrderId: order.id, partId: item.partId, description: item.description, quantity: item.quantity,
    unitPriceMinor: decimalToMinorUnits(item.unitPrice, DECIMAL_10_2_MAX_MINOR),
    totalPriceMinor: decimalToMinorUnits(item.totalPrice, DECIMAL_10_2_MAX_MINOR), createdAt: item.createdAt.toISOString(),
  })).sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  const totalAmountMinor = decimalToMinorUnits(order.totalAmount, DECIMAL_10_2_MAX_MINOR);
  if (items.some(item => lineTotalMinor(item.quantity, item.unitPriceMinor) !== item.totalPriceMinor) ||
      aggregateTotalMinor(items) !== totalAmountMinor) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
  let materializedQuoteRevisionId: string | null = null;
  let commercialScopeSource: 'UNPUBLISHED' | 'CURRENT_QUOTE' | 'LAST_APPROVED_QUOTE' = 'UNPUBLISHED';
  if (order.currentQuoteRevisionId || order.lastApprovedQuoteRevisionId) {
    const fingerprint = liveCommercialScopeFingerprint(order);
    for (const [revision, source] of [[order.currentQuoteRevision, 'CURRENT_QUOTE'], [order.lastApprovedQuoteRevision, 'LAST_APPROVED_QUOTE']] as const) {
      if (!revision) continue;
      if (revision.serviceOrderId !== order.id || revision.organizationId !== order.organizationId || revision.customerId !== order.customerId) {
        throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
      }
      if (commercialScopeFingerprint(approvedQuoteAuthorityFromRevision(revision).commercialScope) === fingerprint) {
        materializedQuoteRevisionId = revision.id; commercialScopeSource = source; break;
      }
    }
    if (!materializedQuoteRevisionId) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
  }
  return { diagnosis: order.diagnosis, totalAmountMinor, items,
    currentQuoteRevisionId: order.currentQuoteRevisionId, lastApprovedQuoteRevisionId: order.lastApprovedQuoteRevisionId,
    materializedQuoteRevisionId, commercialScopeSource };
}

export function serializeStaffOrder(order: OrderAggregate, projectionRevision: string) {
  return { contractVersion: 2, projectionRevision,
    id: order.id, friendlyId: order.friendlyId, organizationId: order.organizationId, customerId: order.customerId,
    equipmentId: order.equipmentId, technicianId: order.technicianId, status: order.status,
    problemDescription: order.problemDescription, solution: order.solution,
    createdAt: order.createdAt.toISOString(), updatedAt: order.updatedAt.toISOString(), ...commercialProjection(order),
  };
}

/** CUSTOMER has an explicit projection: no professional/Finance Core fields,
 * raw QuoteRevision, catalog expansion, payment or audit joins. */
export function serializeCustomerOrder(order: OrderAggregate, projectionRevision: string) {
  return { contractVersion: 2, projectionRevision,
    id: order.id, friendlyId: order.friendlyId, organizationId: order.organizationId, customerId: order.customerId,
    equipmentId: order.equipmentId, status: order.status, problemDescription: order.problemDescription,
    solution: order.solution, createdAt: order.createdAt.toISOString(), updatedAt: order.updatedAt.toISOString(),
    ...commercialProjection(order),
  };
}

export type ProjectionRecord = { entityType: string; entityId: string; data: Prisma.InputJsonValue };
export async function readProjection(tx: Prisma.TransactionClient, principal: SyncPrincipal, type: string,
  id: string, revision: string, contractVersion: 1 | 2): Promise<ProjectionRecord | null> {
  if (type === 'SERVICE_ORDER' || type === 'SERVICE_ORDER_ITEM') {
    if (type === 'SERVICE_ORDER_ITEM') {
      const item = await tx.serviceOrderItem.findFirst({ where: { id, serviceOrder: orderScope(principal) }, include: { serviceOrder: true } });
      if (!item) return null;
      if (contractVersion === 1) return { entityType: type, entityId: id, data: {
        id: item.id, serviceOrderId: item.serviceOrderId, partId: item.partId, description: item.description, quantity: item.quantity,
        unitPrice: decimalMoneyText(item.unitPrice), totalPrice: decimalMoneyText(item.totalPrice), createdAt: item.createdAt.toISOString(),
      } };
      id = item.serviceOrderId;
    }
    const order = await tx.serviceOrder.findFirst({ where: { id, ...orderScope(principal) }, include: orderAggregateInclude });
    if (!order) return null;
    if (contractVersion === 2 && !order.currentQuoteRevisionId &&
        await tx.serviceOrderQuoteRevision.count({ where: { serviceOrderId: order.id } }) > 0) {
      throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
    }
    const data = contractVersion === 1 ? toServiceOrderSyncSnapshot(order) :
      principal.role === 'CUSTOMER' ? serializeCustomerOrder(order, revision) : serializeStaffOrder(order, revision);
    return { entityType: 'SERVICE_ORDER', entityId: id, data };
  }
  if (type === 'CUSTOMER') {
    const row = await tx.customer.findFirst({ where: { id, ...customerScope(principal) },
      select: { id: true, name: true, document: true, email: true, phone: true, address: true, createdAt: true, updatedAt: true } });
    return row ? { entityType: type, entityId: id, data: { ...row, createdAt: row.createdAt.toISOString(), updatedAt: row.updatedAt.toISOString(),
      ...(contractVersion === 2 ? { contractVersion: 2, projectionRevision: revision } : {}) } } : null;
  }
  if (type === 'EQUIPMENT') {
    const row = await tx.equipment.findFirst({ where: { id, ...equipmentScope(principal) } });
    return row ? { entityType: type, entityId: id, data: { ...row, createdAt: row.createdAt.toISOString(), updatedAt: row.updatedAt.toISOString(),
      ...(contractVersion === 2 ? { contractVersion: 2, projectionRevision: revision } : {}) } } : null;
  }
  if (type === 'PAYMENT' && principal.role !== 'CUSTOMER') {
    const row = await tx.payment.findFirst({ where: { id, organizationId: principal.organizationId!, serviceOrder: { financeCoreVersion: null } }, include: { customer: { select: { id: true, name: true } } } });
    if (!row) return null;
    return { entityType: type, entityId: id, data: {
      ...serializePayment(row),
      ...(contractVersion === 2 ? { contractVersion: 2, projectionRevision: revision } : {}),
    } };
  }
  return null;
}
