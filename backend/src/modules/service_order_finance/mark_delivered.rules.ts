import type { Payment, PaymentAllocation, Receivable, ReceivableInstallment, ReceivableSchedule } from '@prisma/client';
import { decimalToMinorUnits } from '../../core/money/money.js';

/** Validate the entire locked settlement graph, not just SUM(allocation.amount). */
export function assertDeliverySettlement(
  scope: { id: string; organizationId: string; customerId: string; approvedRevisionId: string; totalMinor: number },
  receivables: Receivable[], schedules: ReceivableSchedule[], installments: ReceivableInstallment[],
  payments: Payment[], allocations: PaymentAllocation[],
): void {
  const invalid = (): never => { throw new RangeError('DELIVERY_FINANCIAL_INTEGRITY_INVALID'); };
  if (receivables.length !== 1) invalid();
  const r = receivables[0];
  const sameScope = (row: { serviceOrderId: string; organizationId: string; customerId: string }) =>
    row.serviceOrderId === scope.id && row.organizationId === scope.organizationId && row.customerId === scope.customerId;
  if (!sameScope(r) || r.lifecycleStatus !== 'ACTIVE' || r.cancelledAt !== null ||
      r.cancelledByUserId !== null || r.cancellationReason !== null ||
      r.sourceQuoteRevisionId !== scope.approvedRevisionId || scope.totalMinor <= 0 ||
      decimalToMinorUnits(r.totalAmount) !== scope.totalMinor) invalid();
  if (schedules.length !== 1) invalid();
  const schedule = schedules[0];
  if (schedule.receivableId !== r.id || schedule.organizationId !== scope.organizationId ||
      schedule.version !== r.currentScheduleVersion || installments.length === 0) invalid();
  const installmentMap = new Map(installments.map(i => [i.id, i]));
  const paymentMap = new Map(payments.map(p => [p.id, p]));
  let installmentTotal = 0n;
  for (const [index, installment] of installments.entries()) {
    if (installment.receivableId !== r.id || installment.organizationId !== scope.organizationId ||
        installment.scheduleId !== schedule.id || installment.scheduleVersion !== schedule.version ||
        installment.sequence !== index + 1) invalid();
    const amount = decimalToMinorUnits(installment.amount);
    if (amount <= 0) invalid();
    installmentTotal += BigInt(amount);
  }
  if (installmentTotal !== BigInt(scope.totalMinor)) invalid();
  const byPayment = new Map<string, bigint>(), byInstallment = new Map<string, bigint>();
  let total = 0n;
  for (const allocation of allocations) {
    const payment = paymentMap.get(allocation.paymentId);
    if (!sameScope(allocation) || allocation.receivableId !== r.id ||
        !installmentMap.has(allocation.installmentId) || !payment || !sameScope(payment) ||
        payment.status !== 'CONFIRMED' || payment.cancelledAt !== null || payment.paidAt === null) invalid();
    const amount = BigInt(decimalToMinorUnits(allocation.amount));
    if (amount <= 0n) invalid();
    total += amount;
    byPayment.set(allocation.paymentId, (byPayment.get(allocation.paymentId) ?? 0n) + amount);
    byInstallment.set(allocation.installmentId, (byInstallment.get(allocation.installmentId) ?? 0n) + amount);
  }
  for (const payment of payments) {
    if (!sameScope(payment)) invalid();
    const amount = BigInt(decimalToMinorUnits(payment.amount));
    if (amount <= 0n) invalid();
    const allocated = byPayment.get(payment.id) ?? 0n;
    switch (payment.status) {
      case 'PENDING':
        if (payment.paidAt !== null || payment.confirmedByUserId !== null ||
            payment.cancelledAt !== null || payment.cancelledByUserId !== null || allocated !== 0n) invalid();
        break;
      case 'CONFIRMED':
        if (!payment.paidAt || !payment.confirmedByUserId || payment.cancelledAt !== null ||
            payment.cancelledByUserId !== null || allocated !== amount) invalid();
        break;
      case 'CANCELLED':
        if (!payment.cancelledAt || !payment.cancelledByUserId || payment.paidAt !== null ||
            payment.confirmedByUserId !== null || allocated !== 0n) invalid();
        break;
      default:
        invalid();
    }
  }
  for (const installment of installments) {
    if ((byInstallment.get(installment.id) ?? 0n) > BigInt(decimalToMinorUnits(installment.amount))) invalid();
  }
  if (total > BigInt(scope.totalMinor)) invalid();
  if (total !== BigInt(scope.totalMinor)) throw new RangeError('DELIVERY_REQUIRES_SETTLED_RECEIVABLE');
}
