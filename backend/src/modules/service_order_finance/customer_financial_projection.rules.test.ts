import test from 'node:test';
import assert from 'node:assert/strict';

import {
  ReceivableLifecycleStatus,
} from '@prisma/client';

import {
  buildCustomerFinancialObligation,
} from './customer_financial_projection.rules.js';

test(
  'FIN-F02 customer projection derives A_RECEBER and due amount without persisted financial status',
  () => {
    const result =
      buildCustomerFinancialObligation({
        lifecycleStatus:
          ReceivableLifecycleStatus
            .ACTIVE,
        totalAmountMinor:
          10_000,
        allocatedAmountMinor:
          0,
        currentDueDateKey:
          '2026-09-15',
        organizationTimeZone:
          'America/Sao_Paulo',
        now:
          new Date(
            '2026-09-01T12:00:00.000Z'
          ),
      });

    assert.equal(
      result.paymentStatus,
      'A_RECEBER'
    );

    assert.equal(
      result.outstandingAmountMinor,
      10_000
    );

    assert.equal(
      result.amountDueMinor,
      10_000
    );

    assert.equal(
      result.currentDueDate,
      '2026-09-15'
    );

    assert.equal(
      result.overdue,
      false
    );
  }
);

test(
  'FIN-F02 customer projection derives partial and paid states from allocations only',
  () => {
    const partial =
      buildCustomerFinancialObligation({
        lifecycleStatus:
          ReceivableLifecycleStatus
            .ACTIVE,
        totalAmountMinor:
          10_000,
        allocatedAmountMinor:
          4_000,
        currentDueDateKey:
          '2026-09-15',
        organizationTimeZone:
          'UTC',
        now:
          new Date(
            '2026-09-01T12:00:00.000Z'
          ),
      });

    assert.equal(
      partial.paymentStatus,
      'PARCIALMENTE_PAGO'
    );

    assert.equal(
      partial.amountDueMinor,
      6_000
    );

    const paid =
      buildCustomerFinancialObligation({
        lifecycleStatus:
          ReceivableLifecycleStatus
            .ACTIVE,
        totalAmountMinor:
          10_000,
        allocatedAmountMinor:
          10_000,
        currentDueDateKey:
          '2026-09-15',
        organizationTimeZone:
          'UTC',
        now:
          new Date(
            '2026-09-20T12:00:00.000Z'
          ),
      });

    assert.equal(
      paid.paymentStatus,
      'PAGO'
    );

    assert.equal(
      paid.outstandingAmountMinor,
      0
    );

    assert.equal(
      paid.amountDueMinor,
      0
    );

    assert.equal(
      paid.currentDueDate,
      null
    );

    assert.equal(
      paid.overdue,
      false
    );
  }
);

test(
  'FIN-F02 cancelled obligation exposes zero due without falsifying payment status as PAGO',
  () => {
    const result =
      buildCustomerFinancialObligation({
        lifecycleStatus:
          ReceivableLifecycleStatus
            .CANCELLED,
        totalAmountMinor:
          10_000,
        allocatedAmountMinor:
          0,
        currentDueDateKey:
          '2026-08-15',
        organizationTimeZone:
          'America/Sao_Paulo',
        now:
          new Date(
            '2026-09-01T12:00:00.000Z'
          ),
      });

    assert.equal(
      result.paymentStatus,
      'A_RECEBER'
    );

    assert.equal(
      result.outstandingAmountMinor,
      10_000
    );

    assert.equal(
      result.amountDueMinor,
      0
    );

    assert.equal(
      result.currentDueDate,
      null
    );

    assert.equal(
      result.overdue,
      false
    );
  }
);

test(
  'FIN-F02 overdue is derived from organization-local civil date and not host timezone',
  () => {
    const instant =
      new Date(
        '2026-09-01T01:30:00.000Z'
      );

    const dueTodayInSaoPaulo =
      buildCustomerFinancialObligation({
        lifecycleStatus:
          ReceivableLifecycleStatus
            .ACTIVE,
        totalAmountMinor:
          10_000,
        allocatedAmountMinor:
          0,
        currentDueDateKey:
          '2026-08-31',
        organizationTimeZone:
          'America/Sao_Paulo',
        now:
          instant,
      });

    assert.equal(
      dueTodayInSaoPaulo.overdue,
      false
    );

    const overdueInSaoPaulo =
      buildCustomerFinancialObligation({
        lifecycleStatus:
          ReceivableLifecycleStatus
            .ACTIVE,
        totalAmountMinor:
          10_000,
        allocatedAmountMinor:
          0,
        currentDueDateKey:
          '2026-08-30',
        organizationTimeZone:
          'America/Sao_Paulo',
        now:
          instant,
      });

    assert.equal(
      overdueInSaoPaulo.overdue,
      true
    );
  }
);

test(
  'FIN-F02 cancelled Receivable with allocations fails closed instead of presenting contradictory projection',
  () => {
    assert.throws(
      () =>
        buildCustomerFinancialObligation({
          lifecycleStatus:
            ReceivableLifecycleStatus
              .CANCELLED,
          totalAmountMinor:
            10_000,
          allocatedAmountMinor:
            1_000,
          currentDueDateKey:
            '2026-09-15',
          organizationTimeZone:
            'UTC',
          now:
            new Date(
              '2026-09-01T12:00:00.000Z'
            ),
        }),
      /Cancelled Receivable/
    );
  }
);
