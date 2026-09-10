import test from 'node:test';
import assert from 'node:assert/strict';

import {
  Prisma,
} from '@prisma/client';

import {
  buildReceivableReschedulePlan,
  parseCivilDueDate,
} from './receivables.fin-f02.rules.js';

test(
  'FIN-F02 reschedule accepts strict valid civil YYYY-MM-DD',
  () => {
    assert.equal(
      parseCivilDueDate(
        '2026-09-30'
      )
        .toISOString()
        .slice(
          0,
          10
        ),
      '2026-09-30'
    );

    assert.throws(
      () =>
        parseCivilDueDate(
          '2026-02-30'
        )
    );

    assert.throws(
      () =>
        parseCivilDueDate(
          '30/09/2026'
        )
    );
  }
);

test(
  'FIN-F02 reschedule creates next immutable schedule only before any effective allocation',
  () => {
    const plan =
      buildReceivableReschedulePlan(
        new Prisma.Decimal(
          '100.00'
        ),
        1,
        0,
        [
          {
            id:
              '11111111-1111-4111-8111-111111111111',
            amountMinor:
              10_000,
            allocatedMinor:
              0,
          },
        ],
        '2026-10-15'
      );

    assert.equal(
      plan.nextScheduleVersion,
      2
    );

    assert.equal(
      plan.outstandingMinor,
      10_000
    );

    assert.equal(
      plan.outstandingAmount
        .toFixed(
          2
        ),
      '100.00'
    );

    assert.equal(
      plan.financialStatus,
      'A_RECEBER'
    );
  }
);

test(
  'FIN-F02-R01 partial effective allocation freezes normal reschedule',
  () => {
    assert.throws(
      () =>
        buildReceivableReschedulePlan(
          new Prisma.Decimal(
            '100.00'
          ),
          1,
          4_000,
          [
            {
              id:
                '11111111-1111-4111-8111-111111111111',
              amountMinor:
                10_000,
              allocatedMinor:
                4_000,
            },
          ],
          '2026-10-15'
        ),
      /zero effective allocations/
    );
  }
);

test(
  'FIN-F02 reschedule fails closed if current schedule capacity diverges from Receivable outstanding',
  () => {
    assert.throws(
      () =>
        buildReceivableReschedulePlan(
          new Prisma.Decimal(
            '100.00'
          ),
          2,
          0,
          [
            {
              id:
                '11111111-1111-4111-8111-111111111111',
              amountMinor:
                7_000,
              allocatedMinor:
                0,
            },
          ],
          '2026-10-15'
        ),
      /does not match/
    );
  }
);

test(
  'FIN-F02 paid Receivable cannot be normally rescheduled after effective allocation',
  () => {
    assert.throws(
      () =>
        buildReceivableReschedulePlan(
          new Prisma.Decimal(
            '100.00'
          ),
          1,
          10_000,
          [
            {
              id:
                '11111111-1111-4111-8111-111111111111',
              amountMinor:
                10_000,
              allocatedMinor:
                10_000,
            },
          ],
          '2026-10-15'
        ),
      /zero effective allocations/
    );
  }
);
