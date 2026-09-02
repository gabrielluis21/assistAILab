import {
  Prisma,
} from '@prisma/client';

import {
  decimalToMinorUnits,
} from '../../core/money/money.js';

export type ReceivableFinancialStatus =
  | 'A_RECEBER'
  | 'PARCIALMENTE_PAGO'
  | 'PAGO';

export type CurrentInstallmentCapacity = {
  id:
    string;

  sequence:
    number;

  amountMinor:
    number;

  allocatedMinor:
    number;
};

export type PaymentAllocationPlanLine = {
  installmentId:
    string;

  sequence:
    number;

  amountMinor:
    number;
};

function assertSafeNonNegativeMinor(
  value:
    number,
  label:
    string
): void {
  if (
    !Number.isSafeInteger(
      value
    ) ||
    value <
      0
  ) {
    throw new RangeError(
      `${label} must be a non-negative safe integer`
    );
  }
}

export function deriveReceivableFinancialStatus(
  totalMinor:
    number,
  allocatedMinor:
    number
): ReceivableFinancialStatus {
  if (
    !Number.isSafeInteger(
      totalMinor
    ) ||
    totalMinor <=
      0
  ) {
    throw new RangeError(
      'totalMinor must be a positive safe integer'
    );
  }

  assertSafeNonNegativeMinor(
    allocatedMinor,
    'allocatedMinor'
  );

  if (
    allocatedMinor >
    totalMinor
  ) {
    throw new RangeError(
      'allocatedMinor cannot exceed totalMinor'
    );
  }

  if (
    allocatedMinor ===
    0
  ) {
    return 'A_RECEBER';
  }

  if (
    allocatedMinor ===
    totalMinor
  ) {
    return 'PAGO';
  }

  return 'PARCIALMENTE_PAGO';
}

export function buildCurrentScheduleAllocationPlan(
  paymentAmountMinor:
    number,
  installments:
    CurrentInstallmentCapacity[]
): PaymentAllocationPlanLine[] {
  if (
    !Number.isSafeInteger(
      paymentAmountMinor
    ) ||
    paymentAmountMinor <=
      0
  ) {
    throw new RangeError(
      'paymentAmountMinor must be a positive safe integer'
    );
  }

  const ordered =
    [
      ...installments,
    ]
      .sort(
        (
          left,
          right
        ) =>
          left.sequence -
            right.sequence ||
          left.id.localeCompare(
            right.id
          )
      );

  const seen =
    new Set<string>();

  for (
    const installment of
    ordered
  ) {
    if (
      seen.has(
        installment.id
      )
    ) {
      throw new RangeError(
        'Duplicate installment id'
      );
    }

    seen.add(
      installment.id
    );

    if (
      !Number.isSafeInteger(
        installment.sequence
      ) ||
      installment.sequence <
        1
    ) {
      throw new RangeError(
        'Installment sequence must be a positive safe integer'
      );
    }

    assertSafeNonNegativeMinor(
      installment.amountMinor,
      'installment amountMinor'
    );

    assertSafeNonNegativeMinor(
      installment.allocatedMinor,
      'installment allocatedMinor'
    );

    if (
      installment
        .allocatedMinor >
      installment
        .amountMinor
    ) {
      throw new RangeError(
        'Installment allocation exceeds amount'
      );
    }
  }

  let remaining =
    paymentAmountMinor;

  const plan:
    PaymentAllocationPlanLine[] =
      [];

  for (
    const installment of
    ordered
  ) {
    if (
      remaining ===
      0
    ) {
      break;
    }

    const capacity =
      installment.amountMinor -
      installment.allocatedMinor;

    if (
      capacity <=
      0
    ) {
      continue;
    }

    const allocated =
      Math.min(
        remaining,
        capacity
      );

    plan.push({
      installmentId:
        installment.id,

      sequence:
        installment.sequence,

      amountMinor:
        allocated,
    });

    remaining -=
      allocated;
  }

  if (
    remaining !==
    0
  ) {
    throw new RangeError(
      'Current Receivable schedule has insufficient outstanding capacity'
    );
  }

  return plan;
}

export function decimalMinor(
  value:
    Prisma.Decimal
): number {
  return decimalToMinorUnits(
    value
  );
}
