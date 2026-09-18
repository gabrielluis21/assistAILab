import { Prisma } from '@prisma/client';
import { prisma } from '../../core/database/prisma.js';
import { syncTransaction } from '../../core/database/sync_transaction.js';
import { resolveLiveAuthority, type ValidatedPrincipal } from '../../core/auth/live_authority.service.js';
import { IdempotencyService } from '../../core/idempotency/idempotency.service.js';
import { computeCanonicalHash } from '../../core/idempotency/canonical_json.js';
import { ConflictError, ForbiddenError } from '../../core/utils/errors.js';
import { serviceOrderCustomerRelationshipService } from '../customer_relationship/service_order_customer_relationship.service.js';
import { approvedQuoteAuthorityFromRevision, liveCommercialScopeFingerprint } from './mark_ready.rules.js';
import { commercialScopeFingerprint } from './commercial_quote_revision.rules.js';
import { assertDeliverySettlement } from './mark_delivered.rules.js';
import type { FinanceCommandResult } from './service_order_finance.service.js';

export async function markDelivered(principal: ValidatedPrincipal, operationId: string, serviceOrderId: string,
  input: { notes?: string }): Promise<FinanceCommandResult> {
  await resolveLiveAuthority(principal);
  const { organizationId, sub: actorUserId } = principal;
  if (!organizationId || !['ADMIN', 'TECHNICIAN'].includes(principal.role)) throw new ForbiddenError();
  const identity = { operationId, organizationId, actorUserId, command: 'FIN_F02_MARK_DELIVERED',
    endpoint: `/api/v1/service-orders/${serviceOrderId}/mark-delivered`,
    requestHash: computeCanonicalHash({ serviceOrderId, notes: input.notes ?? null }) };
  const reservation = await new IdempotencyService(prisma).reserveOrReplay(identity);
  if (reservation.kind === 'REPLAY') return { statusCode: reservation.responseStatus, body: reservation.responseBody as Prisma.InputJsonValue };
  if (reservation.kind === 'KEY_REUSE') throw new ConflictError('IDEMPOTENCY_KEY_REUSE');
  if (reservation.kind === 'IN_PROGRESS') throw new ConflictError('IDEMPOTENCY_IN_PROGRESS');
  if (reservation.kind !== 'ACQUIRED') throw new Error('Unexpected idempotency state');
  return syncTransaction(async tx => {
    await resolveLiveAuthority(principal, tx);
    const complete = async (statusCode: number, body: Prisma.InputJsonValue): Promise<FinanceCommandResult> => {
      await IdempotencyService.completeWithinTransaction(tx, { ...identity, leaseToken: reservation.leaseToken,
        responseStatus: statusCode, responseBody: body });
      return { statusCode, body };
    };
    const fail = (error: string, status = 409) => complete(status, { error });
    // Same lock order as Payment confirmation and Receivable commands.
    await tx.$queryRaw(Prisma.sql`SELECT id FROM service_orders WHERE id = ${serviceOrderId} AND organizationId = ${organizationId} FOR UPDATE`);
    const order = await tx.serviceOrder.findFirst({ where: { id: serviceOrderId, organizationId },
      include: { items: true, currentQuoteRevision: { include: { decision: true } }, lastApprovedQuoteRevision: { include: { decision: true } } } });
    if (!order) return fail('SERVICE_ORDER_NOT_FOUND', 404);
    if (order.financeCoreVersion !== 2) return fail('FIN_F02_ORDER_REQUIRED');
    if (order.status !== 'PRONTO') return fail('DELIVERY_STATUS_CONFLICT');
    const quote = order.lastApprovedQuoteRevision;
    if (!quote || quote.id !== order.lastApprovedQuoteRevisionId || quote.serviceOrderId !== order.id ||
        quote.organizationId !== organizationId || quote.customerId !== order.customerId ||
        quote.decision?.decision !== 'APPROVE' || quote.decision.serviceOrderId !== order.id ||
        quote.decision.organizationId !== organizationId || quote.decision.customerId !== order.customerId ||
        !order.currentQuoteRevision || order.currentQuoteRevision.id !== order.currentQuoteRevisionId ||
        order.currentQuoteRevision.serviceOrderId !== order.id || order.currentQuoteRevision.organizationId !== organizationId ||
        order.currentQuoteRevision.customerId !== order.customerId) return fail('DELIVERY_QUOTE_HISTORY_INVALID');
    if (order.currentQuoteRevision.id !== quote.id) {
      const current = order.currentQuoteRevision;
      if (current.revisionNumber <= quote.revisionNumber || current.decision?.decision !== 'REJECT' ||
          current.decision.serviceOrderId !== order.id || current.decision.organizationId !== organizationId ||
          current.decision.customerId !== order.customerId) return fail('DELIVERY_QUOTE_HISTORY_INVALID');
    }
    let totalMinor: number;
    try {
      const authority = approvedQuoteAuthorityFromRevision(quote);
      approvedQuoteAuthorityFromRevision(order.currentQuoteRevision);
      if (commercialScopeFingerprint(authority.commercialScope) !== liveCommercialScopeFingerprint(order)) {
        return fail('DELIVERY_QUOTE_HISTORY_INVALID');
      }
      totalMinor = authority.commercialScope.totalAmountMinor;
    } catch { return fail('DELIVERY_QUOTE_HISTORY_INVALID'); }
    await tx.$queryRaw(Prisma.sql`SELECT id FROM receivables WHERE serviceOrderId = ${order.id} ORDER BY id FOR UPDATE`);
    const receivables = await tx.receivable.findMany({ where: { serviceOrderId: order.id } });
    if (receivables.length !== 1) return fail('DELIVERY_FINANCIAL_INTEGRITY_INVALID');
    const receivable = receivables[0];
    await tx.$queryRaw(Prisma.sql`SELECT id FROM receivable_schedules WHERE receivableId = ${receivable.id}
      AND version = ${receivable.currentScheduleVersion} ORDER BY id FOR UPDATE`);
    const schedules = await tx.receivableSchedule.findMany({ where: { receivableId: receivable.id, version: receivable.currentScheduleVersion } });
    await tx.$queryRaw(Prisma.sql`SELECT id FROM receivable_installments WHERE receivableId = ${receivable.id}
      AND scheduleVersion = ${receivable.currentScheduleVersion} ORDER BY sequence, id FOR UPDATE`);
    const installments = await tx.receivableInstallment.findMany({ where: { receivableId: receivable.id, scheduleVersion: receivable.currentScheduleVersion },
      orderBy: [{ sequence: 'asc' }, { id: 'asc' }] });
    await tx.$queryRaw(Prisma.sql`SELECT id FROM payments WHERE serviceOrderId = ${order.id} ORDER BY id FOR UPDATE`);
    const payments = await tx.payment.findMany({ where: { serviceOrderId: order.id } });
    const allocations = await tx.paymentAllocation.findMany({ where: { OR: [
      { serviceOrderId: order.id }, { receivableId: receivable.id },
      { installmentId: { in: installments.map(i => i.id) } }, { paymentId: { in: payments.map(p => p.id) } },
    ] } });
    try {
      assertDeliverySettlement({ id: order.id, organizationId, customerId: order.customerId,
        approvedRevisionId: quote.id, totalMinor }, receivables, schedules, installments, payments, allocations);
    } catch (error) {
      return fail(error instanceof RangeError && error.message === 'DELIVERY_REQUIRES_SETTLED_RECEIVABLE'
        ? error.message : 'DELIVERY_FINANCIAL_INTEGRITY_INVALID');
    }
    await tx.serviceOrder.update({ where: { id: order.id }, data: { status: 'ENTREGUE' } });
    await tx.serviceOrderStatusHistory.create({ data: { serviceOrderId: order.id, previousStatus: 'PRONTO', newStatus: 'ENTREGUE',
      changedById: actorUserId, notes: input.notes ?? 'FIN-F02 MARK DELIVERED' } });
    await serviceOrderCustomerRelationshipService.registerStatusTransition({ serviceOrderId: order.id, customerId: order.customerId,
      organizationId, previousStatus: 'PRONTO', newStatus: 'ENTREGUE' }, tx);
    await tx.financialAuditEvent.create({ data: { organizationId, serviceOrderId: order.id, actorUserId,
      origin: 'USER_COMMAND', eventType: 'SERVICE_ORDER_DELIVERED', entityType: 'SERVICE_ORDER', entityId: order.id,
      operationId, ordinal: 1, metadata: { receivableId: receivable.id, totalAmountMinor: totalMinor } } });
    return complete(200, { order: { id: order.id, status: 'ENTREGUE', customerId: order.customerId, organizationId } });
  });
}
