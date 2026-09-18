import { ServiceOrderStatus } from '@prisma/client';
import { z } from 'zod';
import type { FinanceCommandResult } from './service_order_finance.service.js';
import { ConflictError } from '../../core/utils/errors.js';

const decisionResponse = z.object({
  order: z.object({ id: z.string().uuid(), status: z.nativeEnum(ServiceOrderStatus) }),
  quoteDecision: z.object({
    quoteRevisionId: z.string().uuid(), decision: z.enum(['APPROVE', 'REJECT']),
    reason: z.string().nullable(), decidedAt: z.string().datetime(),
  }),
});

/** Apply to fresh responses AND stored replays; never mutate idempotency history. */
export function customerQuoteDecisionResponse(result: FinanceCommandResult): FinanceCommandResult {
  if (result.statusCode !== 200) {
    const body = z.object({ error: z.enum(['SERVICE_ORDER_NOT_FOUND', 'FIN_F02_ORDER_REQUIRED',
      'QUOTE_REVISION_NOT_CURRENT', 'QUOTE_DECISION_STATUS_CONFLICT', 'QUOTE_REVISION_NOT_AVAILABLE',
      'QUOTE_APPROVAL_HISTORY_CONFLICT', 'REAPPROVAL_REQUIRES_PRIOR_APPROVED_REVISION',
      'QUOTE_REVISION_ALREADY_DECIDED']) }).safeParse(result.body);
    if (!body.success) throw new ConflictError('CUSTOMER_QUOTE_RESPONSE_INVALID');
    return { statusCode: result.statusCode, body: { error: body.data.error } };
  }
  const parsed = decisionResponse.safeParse(result.body);
  if (!parsed.success) throw new ConflictError('CUSTOMER_QUOTE_RESPONSE_INVALID');
  return { statusCode: result.statusCode, body: {
    serviceOrderId: parsed.data.order.id, status: parsed.data.order.status,
    quoteDecision: parsed.data.quoteDecision,
  } };
}
