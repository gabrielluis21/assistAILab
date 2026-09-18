import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Prisma } from '@prisma/client';
import type { Receivable, Payment } from '@prisma/client';
import { customerQuoteDecisionResponse } from './customer_quote.projection.js';
import { assertDeliverySettlement } from './mark_delivered.rules.js';
import { isFinanceCommandOnlyStatusTransition } from '../service_orders/service_order_state_machine.js';
import { deliveryPaymentCases } from './delivery_payment.test-cases.js';

test('CUSTOMER fresh and historical quote-decision results are minimized without modifying stored history', () => {
  const body = { order: { id: randomUUID(), status: 'EM_EXECUCAO', financeCoreVersion: 2,
    currentQuoteRevisionId: randomUUID(), lastApprovedQuoteRevisionId: randomUUID(), organizationId: randomUUID() },
  quoteDecision: { id: randomUUID(), quoteRevisionId: randomUUID(), decision: 'APPROVE', reason: null,
    decidedAt: new Date().toISOString(), customerId: randomUUID(), quoteHash: 'private' } };
  const original = structuredClone(body);
  const result = customerQuoteDecisionResponse({ statusCode: 200, body });
  assert.deepEqual(result.body, { serviceOrderId: body.order.id, status: body.order.status,
    quoteDecision: { quoteRevisionId: body.quoteDecision.quoteRevisionId, decision: 'APPROVE', reason: null, decidedAt: body.quoteDecision.decidedAt } });
  assert.deepEqual(body, original);
  assert.deepEqual(customerQuoteDecisionResponse({ statusCode: 409, body: { error: 'QUOTE_REVISION_ALREADY_DECIDED',
    customerId: 'private', decision: 'APPROVE' } }).body, { error: 'QUOTE_REVISION_ALREADY_DECIDED' });
  for (const invalid of [{}, { ...body, quoteDecision: { ...body.quoteDecision, decision: 'UNKNOWN' } }]) {
    assert.throws(() => customerQuoteDecisionResponse({ statusCode: 200, body: invalid }), /CUSTOMER_QUOTE_RESPONSE_INVALID/);
  }
  assert.throws(() => customerQuoteDecisionResponse({ statusCode: 500, body: { error: 'PRIVATE_DATA' } }), /CUSTOMER_QUOTE_RESPONSE_INVALID/);
});

function settlement() {
  const now = new Date();
  const scope = { id: 'order', organizationId: 'org', customerId: 'customer', approvedRevisionId: 'quote', totalMinor: 2468 };
  const shared = { organizationId: 'org', customerId: 'customer', serviceOrderId: 'order', createdAt: now, updatedAt: now };
  const receivables: Receivable[] = [{ ...shared, id: 'receivable', sourceQuoteRevisionId: 'quote', totalAmount: new Prisma.Decimal('24.68'),
    lifecycleStatus: 'ACTIVE' as const, currentScheduleVersion: 1, version: 1, issuedAt: now, createdByUserId: 'staff',
    cancelledAt: null, cancelledByUserId: null, cancellationReason: null }];
  const schedules = [{ id: 'schedule', organizationId: 'org', receivableId: 'receivable', version: 1, createdByUserId: 'staff', createdAt: now }];
  const installments = [{ id: 'installment', organizationId: 'org', receivableId: 'receivable', scheduleId: 'schedule',
    scheduleVersion: 1, sequence: 1, amount: new Prisma.Decimal('24.68'), dueDate: now, createdAt: now }];
  const payments: Payment[] = [{ ...shared, id: 'payment', clientOperationId: randomUUID(), amount: new Prisma.Decimal('24.68'),
    method: 'PIX' as const, status: 'CONFIRMED' as const, cardInstallmentCount: null, notes: null, paidAt: now,
    cancelledAt: null, version: 2, createdByUserId: 'staff', confirmedByUserId: 'staff', cancelledByUserId: null }];
  const allocations = [{ ...shared, id: 'allocation', receivableId: 'receivable', installmentId: 'installment', paymentId: 'payment',
    amount: new Prisma.Decimal('24.68'), createdByUserId: 'staff' }];
  return { scope, receivables, schedules, installments, payments, allocations };
}
function validate(f: ReturnType<typeof settlement>) {
  assertDeliverySettlement(f.scope, f.receivables, f.schedules, f.installments, f.payments, f.allocations);
}
for (const scenario of deliveryPaymentCases('staff')) test(`settled graph with ${scenario.name}`, () => {
  const f = settlement();
  if (scenario.allocated) Object.assign(f.payments[0], scenario.data);
  else f.payments.push({ ...f.payments[0], id: 'additional-payment', clientOperationId: randomUUID(), ...scenario.data });
  if (scenario.valid) assert.doesNotThrow(() => validate(f));
  else assert.throws(() => validate(f), RangeError);
});
test('delivery accepts exact settled minor units; unpaid and partial remain blocked', () => {
  validate(settlement());
  const unpaid = settlement(); unpaid.payments = []; unpaid.allocations = [];
  assert.throws(() => validate(unpaid), /DELIVERY_REQUIRES_SETTLED_RECEIVABLE/);
  const partial = settlement(); partial.payments[0].amount = partial.allocations[0].amount = new Prisma.Decimal('12.34');
  assert.throws(() => validate(partial), /DELIVERY_REQUIRES_SETTLED_RECEIVABLE/);
});
const corruptions: Record<string, (f: ReturnType<typeof settlement>) => void> = {
  'multiple receivables': f => { f.receivables.push({ ...f.receivables[0], id: 'other' }); },
  'missing receivable': f => { f.receivables = []; },
  'wrong quote': f => { f.receivables[0].sourceQuoteRevisionId = 'other'; },
  'wrong total': f => { f.receivables[0].totalAmount = new Prisma.Decimal('24.69'); },
  'cancelled receivable': f => { f.receivables[0].cancelledAt = new Date(); },
  'wrong tenant': f => { f.allocations[0].organizationId = 'other'; },
  'wrong customer': f => { f.payments[0].customerId = 'other'; },
  'wrong order': f => { f.allocations[0].serviceOrderId = 'other'; },
  'wrong receivable': f => { f.allocations[0].receivableId = 'other'; },
  'old schedule': f => { f.installments[0].scheduleVersion = 2; },
  'foreign installment': f => { f.allocations[0].installmentId = 'other'; },
  'foreign payment': f => { f.allocations[0].paymentId = 'other'; },
  'cancelled payment': f => { f.payments[0].cancelledAt = new Date(); },
  'missing allocation': f => { f.allocations = []; },
  'overallocated': f => { f.allocations[0].amount = new Prisma.Decimal('24.69'); },
  'zero allocation': f => { f.allocations[0].amount = new Prisma.Decimal(0); },
  'negative allocation': f => { f.allocations[0].amount = new Prisma.Decimal('-0.01'); },
  'broken installment sum': f => { f.installments[0].amount = new Prisma.Decimal('24.67'); },
};
for (const [name, corrupt] of Object.entries(corruptions)) test(`delivery fails closed: ${name}`, () => {
  const f = settlement(); corrupt(f); assert.throws(() => validate(f));
});
test('generic delivery is blocked only for FIN-F02; legacy transition remains compatible', () => {
  assert.equal(isFinanceCommandOnlyStatusTransition('PRONTO', 'ENTREGUE', 2), true);
  assert.equal(isFinanceCommandOnlyStatusTransition('PRONTO', 'ENTREGUE', null), false);
  assert.equal(isFinanceCommandOnlyStatusTransition('PRONTO', 'CANCELADO', 2), true);
});
