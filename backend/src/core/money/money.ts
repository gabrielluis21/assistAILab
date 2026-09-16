import { Prisma } from '@prisma/client';
import { z } from 'zod';

export const DECIMAL_10_2_MAX_MINOR = 9_999_999_999;
export const DECIMAL_14_2_MAX_MINOR = 99_999_999_999_999;
export const MAX_QUANTITY = 2_147_483_647;
export const moneyMinorSchema = z.number().int().safe().min(0).max(DECIMAL_14_2_MAX_MINOR);
export const positiveMoneyMinorSchema = moneyMinorSchema.min(1);
export const serviceOrderMoneyMinorSchema = moneyMinorSchema.max(DECIMAL_10_2_MAX_MINOR);
export const quantitySchema = z.number().int().min(1).max(MAX_QUANTITY);

export function checkedMinor(value: bigint, maximum = DECIMAL_14_2_MAX_MINOR): number {
  if (value < 0n || value > BigInt(maximum) || value > BigInt(Number.MAX_SAFE_INTEGER)) {
    throw new RangeError('MONEY_RANGE_INVALID');
  }
  return Number(value);
}

/** A wire adapter, never a rounding policy. IEEE-754 noise stays invalid. */
export function legacyMoneyToMinor(value: unknown, maximum = DECIMAL_10_2_MAX_MINOR): number {
  if (typeof value !== 'string' && (typeof value !== 'number' || !Number.isFinite(value) || Object.is(value, -0))) {
    throw new RangeError('MONEY_LEGACY_INVALID');
  }
  const text = String(value);
  // Bound input before BigInt parsing, including leading-zero abuse.
  if (text.length > 32) throw new RangeError('MONEY_LEGACY_INVALID');
  const match = /^(0|[1-9][0-9]*)(?:\.([0-9]{1,2}))?$/.exec(text);
  if (!match) throw new RangeError('MONEY_LEGACY_INVALID');
  return checkedMinor(BigInt(match[1]) * 100n + BigInt((match[2] ?? '').padEnd(2, '0')), maximum);
}

export function minorUnitsToDecimalText(amountMinor: number | bigint, maximum = DECIMAL_14_2_MAX_MINOR): string {
  if (typeof amountMinor === 'number') moneyMinorSchema.parse(amountMinor);
  const minor = BigInt(amountMinor);
  checkedMinor(minor, maximum);
  return `${minor / 100n}.${(minor % 100n).toString().padStart(2, '0')}`;
}

export function minorUnitsToDecimal(amountMinor: number | bigint, maximum = DECIMAL_14_2_MAX_MINOR): Prisma.Decimal {
  return new Prisma.Decimal(minorUnitsToDecimalText(amountMinor, maximum));
}

export function decimalToMinorUnits(value: Prisma.Decimal, maximum = DECIMAL_14_2_MAX_MINOR): number {
  const minor = value.mul(100);
  if (!minor.isFinite() || !minor.isInteger() || minor.isNegative() || minor.gt(maximum)) {
    throw new RangeError('MONEY_DECIMAL_INVALID');
  }
  // Decimal arithmetic and range/integrality proofs precede any Number conversion.
  return checkedMinor(BigInt(minor.toFixed(0)), maximum);
}

export function decimalMoneyText(value: Prisma.Decimal, maximum = DECIMAL_14_2_MAX_MINOR): string {
  return minorUnitsToDecimalText(decimalToMinorUnits(value, maximum), maximum);
}

export function lineTotalMinor(quantity: number, unitPriceMinor: number): number {
  quantitySchema.parse(quantity);
  serviceOrderMoneyMinorSchema.parse(unitPriceMinor);
  return checkedMinor(BigInt(quantity) * BigInt(unitPriceMinor), DECIMAL_10_2_MAX_MINOR);
}

export function aggregateTotalMinor(items: ReadonlyArray<{ quantity: number; unitPriceMinor: number }>): number {
  return checkedMinor(items.reduce((sum, item) => sum + BigInt(lineTotalMinor(item.quantity, item.unitPriceMinor)), 0n), DECIMAL_10_2_MAX_MINOR);
}
