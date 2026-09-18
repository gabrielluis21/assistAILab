import type { FastifyReply, FastifyRequest } from 'fastify';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { syncRead } from '../../core/database/sync_transaction.js';
import { resolveLiveAuthority } from '../../core/auth/live_authority.service.js';
import { ConflictError, NotFoundError } from '../../core/utils/errors.js';
import { authorizeFinanceCustomerMutationLive } from './service_order_finance.authorization.js';
import { publishQuoteParamsSchema } from './service_order_finance.schema.js';
import { approvedQuoteAuthorityFromRevision, liveCommercialScopeFingerprint } from './mark_ready.rules.js';
import { commercialScopeFingerprint } from './commercial_quote_revision.rules.js';
import { orderAggregateInclude } from '../sync/sync.projection.js';

export async function customerQuoteHandler(request: FastifyRequest, reply: FastifyReply) {
  const principal = getAuthUser(request);
  const customerId = await authorizeFinanceCustomerMutationLive(principal);
  const { id } = publishQuoteParamsSchema.parse(request.params);
  const result = await syncRead(async tx => {
    await resolveLiveAuthority(principal, tx);
    const order = await tx.serviceOrder.findFirst({ where: { id, customerId }, include: orderAggregateInclude });
    if (!order) throw new NotFoundError('SERVICE_ORDER_NOT_FOUND');
    const revision = order.currentQuoteRevision;
    const actionable = ['AGUARDANDO_APROVACAO', 'AGUARDANDO_REAPROVACAO'].includes(order.status);
    if (!revision && !order.currentQuoteRevisionId && !actionable) throw new ConflictError('CUSTOMER_QUOTE_NOT_ACTIONABLE');
    if (order.financeCoreVersion !== 2 || !revision || revision.id !== order.currentQuoteRevisionId ||
        revision.serviceOrderId !== order.id || revision.organizationId !== order.organizationId ||
        revision.customerId !== customerId) {
      throw new ConflictError('CUSTOMER_QUOTE_HISTORY_INVALID');
    }
    const decision = await tx.customerQuoteDecision.findUnique({ where: { quoteRevisionId: revision.id } });
    if (decision) {
      if (decision.serviceOrderId !== order.id || decision.organizationId !== order.organizationId || decision.customerId !== customerId) {
        throw new ConflictError('CUSTOMER_QUOTE_HISTORY_INVALID');
      }
      throw new ConflictError('QUOTE_REVISION_ALREADY_DECIDED');
    }
    if (!actionable) throw new ConflictError('CUSTOMER_QUOTE_NOT_ACTIONABLE');
    const initial = order.status === 'AGUARDANDO_APROVACAO';
    if (initial !== (order.lastApprovedQuoteRevisionId === null)) throw new ConflictError('CUSTOMER_QUOTE_HISTORY_INVALID');
    const priorDecision = order.lastApprovedQuoteRevisionId ? await tx.customerQuoteDecision.findUnique({
      where: { quoteRevisionId: order.lastApprovedQuoteRevisionId },
    }) : null;
    let scope;
    try {
      scope = approvedQuoteAuthorityFromRevision(revision).commercialScope;
      if (commercialScopeFingerprint(scope) !== liveCommercialScopeFingerprint(order)) throw new Error('Unmaterialized quote');
      if (!initial) {
        const approved = order.lastApprovedQuoteRevision;
        if (!approved || approved.id === revision.id || approved.serviceOrderId !== id ||
            approved.organizationId !== order.organizationId || approved.customerId !== customerId ||
            approved.revisionNumber >= revision.revisionNumber) throw new Error('Invalid prior quote');
        approvedQuoteAuthorityFromRevision(approved);
        if (!priorDecision || priorDecision.decision !== 'APPROVE' || priorDecision.serviceOrderId !== id ||
            priorDecision.organizationId !== order.organizationId || priorDecision.customerId !== customerId) {
          throw new Error('Invalid prior approval');
        }
      }
    } catch {
      throw new ConflictError('CUSTOMER_QUOTE_HISTORY_INVALID');
    }
    return { serviceOrderId: id, quote: {
      quoteRevisionId: revision.id, revisionNumber: revision.revisionNumber,
      decisionMode: initial ? 'INITIAL_APPROVAL' : 'REAPPROVAL', diagnosis: scope.diagnosis,
      items: scope.items.map(({ description, quantity, unitPriceMinor, totalPriceMinor }) =>
        ({ description, quantity, unitPriceMinor, totalPriceMinor })),
      totalAmountMinor: scope.totalAmountMinor, changeReason: revision.changeReason,
      createdAt: revision.createdAt.toISOString(),
    } };
  });
  return reply.send(result);
}
