import {
  ReceivableLifecycleStatus,
} from '@prisma/client';

import {
  civilDateKeyToUtcDate,
  organizationLocalDateKey,
} from '../../core/time/organization_time.js';

import {
  deriveReceivableFinancialStatus,
  type ReceivableFinancialStatus,
} from '../payments/payments.fin-f02.rules.js';

export type CustomerConfirmedPaymentProjection = {
  amountMinor:
    number;

  method:
    string;

  paidAt:
    string;

  cardInstallmentCount:
    number |
    null;
};

export type CustomerFinancialObligationProjection = {
  lifecycleStatus:
    'ACTIVE' |
    'CANCELLED';

  totalAmountMinor:
    number;

  allocatedAmountMinor:
    number;

  outstandingAmountMinor:
    number;

  amountDueMinor:
    number;

  paymentStatus:
    ReceivableFinancialStatus;

  currentDueDate:
    string |
    null;

  overdue:
    boolean;
};

export type CustomerFinancialProjection = {
  serviceOrderId:
    string;

  obligation:
    CustomerFinancialObligationProjection |
    null;

  confirmedPayments:
    CustomerConfirmedPaymentProjection[];
};

export type BuildCustomerFinancialObligationInput = {
  lifecycleStatus:
    ReceivableLifecycleStatus;

  totalAmountMinor:
    number;

  allocatedAmountMinor:
    number;

  currentDueDateKey:
    string;

  organizationTimeZone:
    string;

  now:
    Date;
};

function assertPositiveMinor(
  value:
    number,
  label:
    string
): void {
  if (
    !Number.isSafeInteger(
      value
    ) ||
    value <=
      0
  ) {
    throw new RangeError(
      `${label} must be a positive safe integer`
    );
  }
}

function assertNonNegativeMinor(
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

export function buildCustomerFinancialObligation(
  input:
    BuildCustomerFinancialObligationInput
): CustomerFinancialObligationProjection {
  assertPositiveMinor(
    input.totalAmountMinor,
    'totalAmountMinor'
  );

  assertNonNegativeMinor(
    input.allocatedAmountMinor,
    'allocatedAmountMinor'
  );

  /**
   * Validate the persisted civil DATE before comparing date keys.
   */
  civilDateKeyToUtcDate(
    input.currentDueDateKey
  );

  const paymentStatus =
    deriveReceivableFinancialStatus(
      input.totalAmountMinor,
      input.allocatedAmountMinor
    );

  const outstandingAmountMinor =
    input.totalAmountMinor -
    input.allocatedAmountMinor;

  if (
    input.lifecycleStatus ===
      ReceivableLifecycleStatus
        .CANCELLED &&
    input.allocatedAmountMinor !==
      0
  ) {
    throw new RangeError(
      'Cancelled Receivable cannot expose effective allocations'
    );
  }

  const activeAndDue =
    input.lifecycleStatus ===
      ReceivableLifecycleStatus
        .ACTIVE &&
    outstandingAmountMinor >
      0;

  const todayKey =
    organizationLocalDateKey(
      input.now,
      input.organizationTimeZone
    );

  return {
    lifecycleStatus:
      input.lifecycleStatus,

    totalAmountMinor:
      input.totalAmountMinor,

    allocatedAmountMinor:
      input.allocatedAmountMinor,

    outstandingAmountMinor,

    amountDueMinor:
      input.lifecycleStatus ===
        ReceivableLifecycleStatus
          .ACTIVE
        ? outstandingAmountMinor
        : 0,

    paymentStatus,

    currentDueDate:
      activeAndDue
        ? input.currentDueDateKey
        : null,

    overdue:
      activeAndDue &&
      input.currentDueDateKey <
        todayKey,
  };
}
