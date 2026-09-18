import { Prisma, type Payment } from '@prisma/client';

type PaymentState = Pick<Payment, 'status' | 'amount' | 'paidAt' | 'confirmedByUserId' | 'cancelledAt' | 'cancelledByUserId'>;

/** Shared adversarial fixtures: each graph already has enough confirmed money. */
export function deliveryPaymentCases(actor: string) {
  const now = new Date('2026-09-18T00:00:00Z');
  const pending: PaymentState = { status: 'PENDING', amount: new Prisma.Decimal('24.68'), paidAt: null,
    confirmedByUserId: null, cancelledAt: null, cancelledByUserId: null };
  const confirmed: PaymentState = { ...pending, status: 'CONFIRMED', paidAt: now, confirmedByUserId: actor };
  const cancelled: PaymentState = { ...pending, status: 'CANCELLED', cancelledAt: now, cancelledByUserId: actor };
  const cases: { name: string; data: PaymentState; allocated: boolean; valid: boolean }[] = [];
  for (const base of [pending, confirmed, cancelled]) {
    const allocated = base.status === 'CONFIRMED';
    cases.push({ name: `${base.status} coherent`, data: base, allocated, valid: true });
    for (const amount of ['0.00', '-0.01']) cases.push({ name: `${base.status} amount ${amount}`,
      data: { ...base, amount: new Prisma.Decimal(amount) }, allocated, valid: false });
    for (const field of ['paidAt', 'confirmedByUserId', 'cancelledAt', 'cancelledByUserId'] as const) {
      const contradictory = base[field] === null ? (field.endsWith('At') ? now : actor) : null;
      cases.push({ name: `${base.status} contradictory ${field}`, data: { ...base, [field]: contradictory }, allocated, valid: false });
    }
  }
  cases.push({ name: 'CANCELLED missing both cancellation fields', data: { ...cancelled, cancelledAt: null, cancelledByUserId: null }, allocated: false, valid: false });
  cases.push({ name: 'PENDING with both confirmation fields', data: { ...pending, paidAt: now, confirmedByUserId: actor }, allocated: false, valid: false });
  cases.push({ name: 'PENDING with allocations', data: pending, allocated: true, valid: false });
  cases.push({ name: 'CANCELLED with allocations', data: cancelled, allocated: true, valid: false });
  return cases;
}
