import {
  Prisma,
} from '@prisma/client';

import {
  decimalToMinorUnits,
  minorUnitsToDecimal,
} from '../../core/money/money.js';

import {
  deriveReceivableFinancialStatus,
  type ReceivableFinancialStatus,
} from '../payments/payments.fin-f02.rules.js';

export type CurrentScheduleInstallmentState = {
  id:
    string;

  amountMinor:
    number;

  allocatedMinor:
    number;
};

export type ReschedulePlan = {
  nextScheduleVersion:
    number;

  outstandingMinor:
    number;

  outstandingAmount:
    Prisma.Decimal;

  dueDate:
    Date;

  financialStatus:
    ReceivableFinancialStatus;
};

export function parseCivilDueDate(
  value:
    string
): Date {
  if (
    !/^\d{4}-\d{2}-\d{2}$/
      .test(
        value
      )
  ) {
    throw new RangeError(
      'dueDate must use YYYY-MM-DD'
    );
  }

  const [
    yearText,
    monthText,
    dayText,
  ] =
    value.split(
      '-'
    );

  const year =
    Number(
      yearText
    );

  const month =
    Number(
      monthText
    );

  const day =
    Number(
      dayText
    );

  const result =
    new Date(
      Date.UTC(
        year,
        month -
          1,
        day
      )
    );

  if (
    result
      .toISOString()
      .slice(
        0,
        10
      ) !==
    value
  ) {
    throw new RangeError(
      'dueDate is not a valid civil date'
    );
  }

  return result;
}

function assertSafeMinor(
  value:
    number,
  label:
    string
) {
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

export function buildReceivableReschedulePlan(
  receivableTotal:
    Prisma.Decimal,
  currentScheduleVersion:
    number,
  allocatedTotalMinor:
    number,
  currentInstallments:
    CurrentScheduleInstallmentState[],
  requestedDueDate:
    string
): ReschedulePlan {
  const totalMinor =
    decimalToMinorUnits(
      receivableTotal
    );

  if (
    totalMinor <=
    0
  ) {
    throw new RangeError(
      'Receivable total must be positive'
    );
  }

  if (
    !Number.isSafeInteger(
      currentScheduleVersion
    ) ||
    currentScheduleVersion <
      1
  ) {
    throw new RangeError(
      'currentScheduleVersion must be positive'
    );
  }

  assertSafeMinor(
    allocatedTotalMinor,
    'allocatedTotalMinor'
  );

  if (
    allocatedTotalMinor >
    totalMinor
  ) {
    throw new RangeError(
      'Allocated total exceeds Receivable total'
    );
  }

  /**
   * FIN-F02-R01
   *
   * Normal due-date reschedule is allowed only before the first
   * effective allocation. Any positive allocation means that money has
   * already been applied to the obligation; changing the remaining
   * schedule after that point is financial renegotiation and belongs to
   * a separately reviewed command/gate.
   */
  if (
    allocatedTotalMinor !==
    0
  ) {
    throw new RangeError(
      'Receivable reschedule requires zero effective allocations'
    );
  }

  if (
    currentInstallments.length ===
    0
  ) {
    throw new RangeError(
      'Current schedule must contain installments'
    );
  }

  const seen =
    new Set<string>();

  let currentOutstandingMinor =
    0;

  for (
    const installment of
    currentInstallments
  ) {
    if (
      seen.has(
        installment.id
      )
    ) {
      throw new RangeError(
        'Duplicate current installment id'
      );
    }

    seen.add(
      installment.id
    );

    assertSafeMinor(
      installment.amountMinor,
      'installment amountMinor'
    );

    assertSafeMinor(
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

    currentOutstandingMinor +=
      installment.amountMinor -
      installment.allocatedMinor;
  }

  const outstandingMinor =
    totalMinor -
    allocatedTotalMinor;

  if (
    outstandingMinor <=
    0
  ) {
    throw new RangeError(
      'Receivable has no outstanding balance'
    );
  }

  if (
    currentOutstandingMinor !==
    outstandingMinor
  ) {
    throw new RangeError(
      'Current schedule outstanding does not match Receivable outstanding'
    );
  }

  return {
    nextScheduleVersion:
      currentScheduleVersion +
      1,

    outstandingMinor,

    outstandingAmount:
      minorUnitsToDecimal(
        outstandingMinor
      ),

    dueDate:
      parseCivilDueDate(
        requestedDueDate
      ),

    financialStatus:
      deriveReceivableFinancialStatus(
        totalMinor,
        allocatedTotalMinor
      ),
  };
}
