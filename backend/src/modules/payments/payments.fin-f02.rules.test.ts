import test from 'node:test';
import assert from 'node:assert/strict';

import {
  createPaymentSchema,
} from './payments.schema.js';

import {
  buildCurrentScheduleAllocationPlan,
  deriveReceivableFinancialStatus,
} from './payments.fin-f02.rules.js';

test(
  'FIN-F02 cardInstallmentCount accepts only 1..24 on credit card metadata',
  () => {
    assert.equal(
      createPaymentSchema
        .parse({
          serviceOrderId:
            '11111111-1111-4111-8111-111111111111',
          amountMinor:
            10_000,
          method:
            'CARTAO_CREDITO',
          cardInstallmentCount:
            12,
        })
        .cardInstallmentCount,
      12
    );

    assert.equal(
      createPaymentSchema
        .safeParse({
          serviceOrderId:
            '11111111-1111-4111-8111-111111111111',
          amountMinor:
            10_000,
          method:
            'PIX',
          cardInstallmentCount:
            2,
        })
        .success,
      false
    );

    assert.equal(
      createPaymentSchema
        .safeParse({
          serviceOrderId:
            '11111111-1111-4111-8111-111111111111',
          amountMinor:
            10_000,
          method:
            'CARTAO_CREDITO',
          cardInstallmentCount:
            25,
        })
        .success,
      false
    );
  }
);

test(
  'FIN-F02 financial status is derived only from total versus immutable allocation sum',
  () => {
    assert.equal(
      deriveReceivableFinancialStatus(
        10_000,
        0
      ),
      'A_RECEBER'
    );

    assert.equal(
      deriveReceivableFinancialStatus(
        10_000,
        2_500
      ),
      'PARCIALMENTE_PAGO'
    );

    assert.equal(
      deriveReceivableFinancialStatus(
        10_000,
        10_000
      ),
      'PAGO'
    );

    assert.throws(
      () =>
        deriveReceivableFinancialStatus(
          10_000,
          10_001
        )
    );
  }
);

test(
  'FIN-F02 allocation uses only current schedule capacity in sequence then UUID order',
  () => {
    assert.deepEqual(
      buildCurrentScheduleAllocationPlan(
        7_000,
        [
          {
            id:
              'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
            sequence:
              2,
            amountMinor:
              5_000,
            allocatedMinor:
              0,
          },
          {
            id:
              'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            sequence:
              1,
            amountMinor:
              5_000,
            allocatedMinor:
              3_000,
          },
        ]
      ),
      [
        {
          installmentId:
            'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
          sequence:
            1,
          amountMinor:
            2_000,
        },
        {
          installmentId:
            'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          sequence:
            2,
          amountMinor:
            5_000,
        },
      ]
    );
  }
);

test(
  'FIN-F02 allocation fails closed when current schedule cannot absorb candidate payment',
  () => {
    assert.throws(
      () =>
        buildCurrentScheduleAllocationPlan(
          5_001,
          [
            {
              id:
                'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
              sequence:
                1,
              amountMinor:
                5_000,
              allocatedMinor:
                0,
            },
          ]
        ),
      /insufficient/
    );
  }
);
