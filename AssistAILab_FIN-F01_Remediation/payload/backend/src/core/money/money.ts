import {
  Prisma,
} from '@prisma/client';

import {
  z,
} from 'zod';

/**
 * DECIMAL(14,2): 12 integer digits + 2 fractional digits.
 * Maximum 999,999,999,999.99 => 99,999,999,999,999 minor units.
 */
export const DECIMAL_14_2_MAX_MINOR =
  99_999_999_999_999;

export const moneyMinorSchema =
  z.number()
    .int()
    .safe()
    .min(0)
    .max(
      DECIMAL_14_2_MAX_MINOR
    );

export const positiveMoneyMinorSchema =
  z.number()
    .int()
    .safe()
    .min(1)
    .max(
      DECIMAL_14_2_MAX_MINOR
    );

export function minorUnitsToDecimal(
  amountMinor: number
): Prisma.Decimal {
  const validated =
    moneyMinorSchema.parse(
      amountMinor
    );

  return new Prisma.Decimal(
    validated
  ).div(100);
}

export function decimalToMinorUnits(
  value: Prisma.Decimal
): number {
  const minor =
    value.mul(100).toNumber();

  return moneyMinorSchema.parse(
    minor
  );
}
