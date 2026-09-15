import { Prisma, ServiceOrderStatus } from '@prisma/client';
import { z } from 'zod';
import { ConflictError, ForbiddenError, NotFoundError } from '../../core/utils/errors.js';
import { aggregateTotalMinor, decimalToMinorUnits, lineTotalMinor, minorUnitsToDecimal, DECIMAL_10_2_MAX_MINOR } from '../../core/money/money.js';
import { isFinanceCommandOnlyStatusTransition, isValidStatusTransition } from '../service_orders/service_order_state_machine.js';
import { serviceOrderCustomerRelationshipService as relationships } from '../customer_relationship/service_order_customer_relationship.service.js';
import { isGenericServiceOrderDeleteBlocked } from './sync.fin-f02.rules.js';
import { customerScope, equipmentScope, orderScope, type SyncPrincipal } from './sync.projection.js';
import type { NormalizedEntry } from './sync.schema.js';

export function assertGenericEquipmentSyncPayload(payload: Record<string, any>): void {
  const owner = payload.owner_type ?? payload.ownerType;
  if (owner && owner !== 'CUSTOMER') {
    throw new ForbiddenError('Equipment ownership cannot be transferred through generic Sync');
  }
  if (payload.organization_id || payload.organizationId) {
    throw new ForbiddenError('organizationId cannot be assigned to Equipment through generic Sync');
  }
  if (payload.organization_purpose || payload.organizationPurpose) {
    throw new ForbiddenError('organizationPurpose cannot be assigned through generic Sync');
  }
}
function assertOperation(entry: NormalizedEntry, exists: boolean): void {
  if (entry.operationType === 'CREATE' && exists) throw new ConflictError('SYNC_ENTITY_ALREADY_EXISTS');
  if (entry.operationType !== 'CREATE' && !exists) throw new NotFoundError('SYNC_ENTITY_NOT_FOUND');
}
function assertStaff(principal: SyncPrincipal): void {
  if (principal.role === 'CUSTOMER') throw new ForbiddenError('SYNC_COMMERCIAL_STAFF_REQUIRED');
}
function assertCommercialMutable(order: { currentQuoteRevisionId: string | null; status: ServiceOrderStatus }): void {
  if (order.currentQuoteRevisionId || !['DRAFT', 'DIAGNOSTICO'].includes(order.status)) {
    throw new ConflictError('FIN_F02_COMMERCIAL_MUTATION_REQUIRES_QUOTE_REVISION');
  }
}
async function lockedOrder(tx: Prisma.TransactionClient, principal: SyncPrincipal, id: string) {
  await tx.$queryRaw`SELECT id FROM service_orders WHERE id = ${id} FOR UPDATE`;
  const order = await tx.serviceOrder.findFirst({ where: { id, ...orderScope(principal) }, include: { items: true } });
  if (!order) throw new NotFoundError('SYNC_ENTITY_NOT_FOUND');
  return order;
}
async function recalculate(tx: Prisma.TransactionClient, serviceOrderId: string): Promise<number> {
  const items = await tx.serviceOrderItem.findMany({ where: { serviceOrderId } });
  const lines = items.map(item => ({ ...item, unitPriceMinor: decimalToMinorUnits(item.unitPrice, DECIMAL_10_2_MAX_MINOR) }));
  const total = aggregateTotalMinor(lines);
  for (const item of lines) {
    const line = lineTotalMinor(item.quantity, item.unitPriceMinor);
    if (decimalToMinorUnits(item.totalPrice, DECIMAL_10_2_MAX_MINOR) !== line) {
      await tx.serviceOrderItem.update({ where: { id: item.id }, data: { totalPrice: minorUnitsToDecimal(line) } });
    }
  }
  await tx.serviceOrder.update({ where: { id: serviceOrderId }, data: { totalAmount: minorUnitsToDecimal(total) } });
  return total;
}
async function mutateItem(tx: Prisma.TransactionClient, principal: SyncPrincipal, entry: NormalizedEntry): Promise<void> {
  assertStaff(principal);
  const p = entry.payload;
  const existing = await tx.serviceOrderItem.findFirst({ where: { id: entry.entityId, serviceOrder: orderScope(principal) } });
  assertOperation(entry, !!existing);
  const parentId = existing?.serviceOrderId ?? p.serviceOrderId;
  if (existing && p.serviceOrderId !== undefined && p.serviceOrderId !== existing.serviceOrderId) throw new ConflictError('SYNC_ITEM_PARENT_IMMUTABLE');
  const order = await lockedOrder(tx, principal, parentId);
  if (entry.assertions.organizationId !== undefined && entry.assertions.organizationId !== order.organizationId) throw new ForbiddenError('SYNC_TENANT_MISMATCH');
  assertCommercialMutable(order);
  if (entry.operationType === 'DELETE') {
    if (entry.assertions.totalPriceMinor !== undefined) throw new ConflictError('SYNC_DELETE_MONEY_FORBIDDEN');
    await tx.serviceOrderItem.delete({ where: { id: entry.entityId } });
  } else {
    const previousPart = existing?.partId ?? null;
    if (p.partId !== undefined && p.partId !== previousPart) throw new ConflictError('PART_TENANCY_REQUIRED');
    const quantity = p.quantity ?? existing!.quantity;
    const unitPriceMinor = p.unitPriceMinor ?? decimalToMinorUnits(existing!.unitPrice, DECIMAL_10_2_MAX_MINOR);
    const total = lineTotalMinor(quantity, unitPriceMinor);
    if (entry.assertions.totalPriceMinor !== undefined && entry.assertions.totalPriceMinor !== total) throw new ConflictError('SYNC_MONEY_ASSERTION_MISMATCH');
    const data = { description: p.description ?? existing!.description, quantity,
      unitPrice: minorUnitsToDecimal(unitPriceMinor), totalPrice: minorUnitsToDecimal(total), partId: previousPart };
    if (existing) await tx.serviceOrderItem.update({ where: { id: entry.entityId }, data });
    else await tx.serviceOrderItem.create({ data: { ...data, id: entry.entityId, serviceOrderId: order.id } });
  }
  await recalculate(tx, order.id);
}
async function mutateOrder(tx: Prisma.TransactionClient, principal: SyncPrincipal, entry: NormalizedEntry): Promise<void> {
  assertStaff(principal);
  const p = entry.payload;
  const organizationId = principal.organizationId!;
  await tx.$queryRaw`SELECT id FROM service_orders WHERE id = ${entry.entityId} FOR UPDATE`;
  const existing = await tx.serviceOrder.findFirst({ where: { id: entry.entityId, organizationId }, include: { items: true } });
  assertOperation(entry, !!existing);
  if (entry.assertions.organizationId !== undefined && entry.assertions.organizationId !== organizationId) throw new ForbiddenError('SYNC_TENANT_MISMATCH');
  if (entry.operationType === 'DELETE') {
    if (entry.assertions.totalAmountMinor !== undefined) throw new ConflictError('SYNC_DELETE_MONEY_FORBIDDEN');
    if (isGenericServiceOrderDeleteBlocked(existing!)) throw new ForbiddenError('FIN_F02_SERVICE_ORDER_GENERIC_DELETE_BLOCKED');
    await tx.serviceOrder.delete({ where: { id: entry.entityId } });
    return;
  }
  if (existing) {
    for (const key of ['customerId', 'equipmentId', 'technicianId', 'problemDescription'] as const) {
      if (p[key] !== undefined && p[key] !== existing[key]) throw new ConflictError('SYNC_ORDER_IDENTITY_IMMUTABLE');
    }
    if (p.diagnosis !== undefined && p.diagnosis !== existing.diagnosis) assertCommercialMutable(existing);
    const status = p.status ?? existing.status;
    if (isFinanceCommandOnlyStatusTransition(existing.status, status, existing.financeCoreVersion)) throw new ConflictError('FINANCE_COMMAND_REQUIRED');
    if (!isValidStatusTransition(existing.status, status)) throw new ConflictError('SYNC_STATUS_TRANSITION_INVALID');
    // Assertions never overwrite a published or unpublished aggregate.
    const derivedTotal = aggregateTotalMinor(existing.items.map(item => ({ quantity: item.quantity, unitPriceMinor: decimalToMinorUnits(item.unitPrice, DECIMAL_10_2_MAX_MINOR) })));
    const total = derivedTotal;
    if (entry.assertions.totalAmountMinor !== undefined && entry.assertions.totalAmountMinor !== total) throw new ConflictError('SYNC_MONEY_ASSERTION_MISMATCH');
    if (existing.currentQuoteRevisionId && decimalToMinorUnits(existing.totalAmount, DECIMAL_10_2_MAX_MINOR) !== total) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
    if (!existing.currentQuoteRevisionId) await recalculate(tx, existing.id);
    await tx.serviceOrder.update({ where: { id: existing.id }, data: {
      status, ...(p.diagnosis !== undefined ? { diagnosis: p.diagnosis } : {}), ...(p.solution !== undefined ? { solution: p.solution } : {}),
    } });
    if (status !== existing.status) {
      await tx.serviceOrderStatusHistory.create({ data: { serviceOrderId: existing.id, previousStatus: existing.status, newStatus: status, changedById: principal.sub } });
      await relationships.registerStatusTransition({ serviceOrderId: existing.id, organizationId, customerId: existing.customerId, previousStatus: existing.status, newStatus: status }, tx);
    }
    return;
  }
  if (p.status !== undefined && p.status !== 'DIAGNOSTICO') throw new ConflictError('SYNC_INITIAL_STATUS_SERVER_OWNED');
  if (entry.assertions.totalAmountMinor !== undefined && entry.assertions.totalAmountMinor !== 0) throw new ConflictError('SYNC_MONEY_ASSERTION_MISMATCH');
  const relation = await tx.customerOrganization.findFirst({ where: { customerId: p.customerId, organizationId, status: 'ACTIVE' } });
  if (!relation) throw new ForbiddenError('SYNC_CUSTOMER_RELATION_REQUIRED');
  const equipment = await tx.equipment.findFirst({ where: { id: p.equipmentId, customerId: p.customerId, ownerType: 'CUSTOMER' } });
  if (!equipment) throw new ForbiddenError('SYNC_EQUIPMENT_CUSTOMER_MISMATCH');
  if (p.technicianId) {
    const member = await tx.membership.findFirst({ where: { userId: p.technicianId, organizationId, role: { in: ['ADMIN', 'TECHNICIAN'] }, user: { status: 'ACTIVE' } } });
    if (!member) throw new ForbiddenError('SYNC_TECHNICIAN_TENANT_MISMATCH');
  }
  const order = await tx.serviceOrder.create({ data: { id: entry.entityId, organizationId, customerId: p.customerId,
    equipmentId: p.equipmentId, technicianId: p.technicianId ?? null, problemDescription: p.problemDescription,
    diagnosis: p.diagnosis ?? null, solution: p.solution ?? null, status: 'DIAGNOSTICO', financeCoreVersion: 2,
    totalAmount: minorUnitsToDecimal(0),
  } });
  await relationships.registerCreated({ serviceOrderId: order.id, organizationId, customerId: order.customerId, status: order.status }, tx);
}

const customerFields = z.object({ name: z.string().min(1).max(500), document: z.string().max(100).nullable().optional(),
  email: z.string().max(500).nullable().optional(), phone: z.string().max(100).nullable().optional(), address: z.string().max(2000).nullable().optional() });
const equipmentFields = z.object({ type: z.string().min(1).max(500), brand: z.string().min(1).max(500), model: z.string().min(1).max(500),
  serialNumber: z.string().max(500).nullable().optional(), notes: z.string().max(10000).nullable().optional() });
function aliased(payload: Record<string, any>, field: string, alias: string): any {
  if (Object.hasOwn(payload, field) && Object.hasOwn(payload, alias)) throw new ConflictError('SYNC_PAYLOAD_ALIAS_AMBIGUOUS');
  return payload[field] ?? payload[alias];
}
export async function mutateSyncEntity(tx: Prisma.TransactionClient, principal: SyncPrincipal, entry: NormalizedEntry): Promise<void> {
  if (entry.entityType === 'SERVICE_ORDER_ITEM') return mutateItem(tx, principal, entry);
  if (entry.entityType === 'SERVICE_ORDER') return mutateOrder(tx, principal, entry);
  const p = entry.payload;
  if (p.id !== undefined && p.id !== entry.entityId) throw new ConflictError('SYNC_ENTITY_ID_MISMATCH');
  if (entry.entityType === 'CUSTOMER') {
    const existing = await tx.customer.findFirst({ where: { id: entry.entityId, ...customerScope(principal) } });
    assertOperation(entry, !!existing);
    if (principal.role === 'CUSTOMER' && entry.entityId !== principal.customerId) throw new ForbiddenError('SYNC_CUSTOMER_MISMATCH');
    if (entry.operationType === 'DELETE') {
      if (principal.role === 'CUSTOMER') throw new ForbiddenError('SYNC_CUSTOMER_DELETE_FORBIDDEN');
      await tx.customerOrganization.delete({ where: { customerId_organizationId: { customerId: entry.entityId, organizationId: principal.organizationId! } } });
    } else {
      const data = (existing ? customerFields.partial() : customerFields).parse(p);
      if (existing) await tx.customer.update({ where: { id: existing.id }, data });
      else {
        await tx.customer.create({ data: { ...customerFields.parse(data), id: entry.entityId } });
        if (principal.organizationId) await tx.customerOrganization.create({ data: { customerId: entry.entityId, organizationId: principal.organizationId } });
      }
    }
    return;
  }
  if (entry.entityType === 'EQUIPMENT') {
    assertGenericEquipmentSyncPayload(p);
    const existing = await tx.equipment.findFirst({ where: { id: entry.entityId, ...equipmentScope(principal) } });
    assertOperation(entry, !!existing);
    if (existing && existing.ownerType !== 'CUSTOMER') throw new ForbiddenError('SYNC_EQUIPMENT_OWNERSHIP_PROTECTED');
    const customerId = aliased(p, 'customerId', 'customer_id') ?? existing?.customerId ?? principal.customerId;
    if (!customerId || (principal.role === 'CUSTOMER' && customerId !== principal.customerId) || (existing && customerId !== existing.customerId)) throw new ForbiddenError('SYNC_EQUIPMENT_CUSTOMER_MISMATCH');
    if (principal.role !== 'CUSTOMER') {
      const relation = await tx.customerOrganization.findFirst({ where: { customerId, organizationId: principal.organizationId!, status: 'ACTIVE' } });
      if (!relation) throw new ForbiddenError('SYNC_CUSTOMER_RELATION_REQUIRED');
    }
    if (entry.operationType === 'DELETE') await tx.equipment.delete({ where: { id: entry.entityId } });
    else {
      const data = (existing ? equipmentFields.partial() : equipmentFields).parse({ ...p, serialNumber: aliased(p, 'serialNumber', 'serial_number') });
      if (existing) await tx.equipment.update({ where: { id: existing.id }, data });
      else await tx.equipment.create({ data: { ...equipmentFields.parse(data), id: entry.entityId, customerId, ownerType: 'CUSTOMER', organizationId: null } });
    }
    return;
  }
  throw new ForbiddenError(entry.entityType === 'PART' ? 'PART_TENANCY_REQUIRED' : 'SYNC_ENTITY_TYPE_FORBIDDEN');
}
