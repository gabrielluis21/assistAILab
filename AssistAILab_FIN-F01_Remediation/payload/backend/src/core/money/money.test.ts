import {
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  Prisma,
} from '@prisma/client';

import {
  DECIMAL_14_2_MAX_MINOR,
  decimalToMinorUnits,
  minorUnitsToDecimal,
  moneyMinorSchema,
  positiveMoneyMinorSchema,
} from './money.js';

describe(
  'core/money DECIMAL(14,2)',
  () => {
    test(
      'accepts exact maximum minor-unit boundary',
      () => {
        assert.equal(
          moneyMinorSchema.parse(
            DECIMAL_14_2_MAX_MINOR
          ),
          DECIMAL_14_2_MAX_MINOR
        );

        assert.equal(
          minorUnitsToDecimal(
            DECIMAL_14_2_MAX_MINOR
          ).toFixed(2),
          '999999999999.99'
        );
      }
    );

    test(
      'rejects one minor unit above DECIMAL(14,2) maximum',
      () => {
        assert.throws(
          () =>
            moneyMinorSchema.parse(
              DECIMAL_14_2_MAX_MINOR + 1
            )
        );
      }
    );

    test(
      'positive Payment money rejects zero',
      () => {
        assert.throws(
          () =>
            positiveMoneyMinorSchema.parse(0)
        );
      }
    );

    test(
      'rejects fractional minor units',
      () => {
        assert.throws(
          () =>
            moneyMinorSchema.parse(100.5)
        );
      }
    );

    test(
      'roundtrips representative minor-unit boundaries exactly',
      () => {
        const cases = [
          0,
          1,
          99,
          100,
          101,
          12_345,
          DECIMAL_14_2_MAX_MINOR,
        ];

        for (const minor of cases) {
          assert.equal(
            decimalToMinorUnits(
              minorUnitsToDecimal(minor)
            ),
            minor
          );
        }
      }
    );

    test(
      'rejects persisted values with more than two decimal places',
      () => {
        assert.throws(
          () =>
            decimalToMinorUnits(
              new Prisma.Decimal('1.001')
            )
        );
      }
    );
  }
);
