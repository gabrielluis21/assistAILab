import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

export const MAX_SERVICE_ORDER_MONEY_MINOR =
  9_999_999_999n;

export type CommercialSemanticLine = {
  partId:
    string |
    null;

  description:
    string;

  quantity:
    number;

  unitPriceMinor:
    number;

  totalPriceMinor:
    number;
};

export type CommercialSemanticScope = {
  diagnosis:
    string |
    null;

  totalAmountMinor:
    number;

  items:
    CommercialSemanticLine[];
};

export function moneyMinorToDecimalText(
  minor:
    bigint
): string {
  if (
    minor <
    0n
  ) {
    throw new RangeError(
      'Money minor units cannot be negative'
    );
  }

  const whole =
    minor /
    100n;

  const cents =
    (
      minor %
      100n
    )
      .toString()
      .padStart(
        2,
        '0'
      );

  return (
    whole
      .toString() +
    '.' +
    cents
  );
}

export function decimalTextToMinor(
  value:
    string
): bigint {
  const match =
    /^(\d+)\.(\d{2})$/
      .exec(
        value
      );

  if (!match) {
    throw new RangeError(
      'Money decimal must use exactly 2 fractional digits'
    );
  }

  return (
    BigInt(
      match[1]
    ) *
      100n +
    BigInt(
      match[2]
    )
  );
}

export function calculateCommercialLineTotalMinor(
  quantity:
    number,
  unitPriceMinor:
    number
): bigint {
  if (
    !Number.isSafeInteger(
      quantity
    ) ||
    quantity <
      1
  ) {
    throw new RangeError(
      'Quantity must be a positive safe integer'
    );
  }

  if (
    !Number.isSafeInteger(
      unitPriceMinor
    ) ||
    unitPriceMinor <
      0
  ) {
    throw new RangeError(
      'unitPriceMinor must be a non-negative safe integer'
    );
  }

  const result =
    BigInt(
      quantity
    ) *
    BigInt(
      unitPriceMinor
    );

  if (
    result >
    MAX_SERVICE_ORDER_MONEY_MINOR
  ) {
    throw new RangeError(
      'Commercial line total exceeds ServiceOrder DECIMAL(10,2)'
    );
  }

  return result;
}

export function calculateCommercialTotalMinor(
  lines:
    Array<{
      quantity:
        number;
      unitPriceMinor:
        number;
    }>
): bigint {
  let total =
    0n;

  for (
    const line of
    lines
  ) {
    total +=
      calculateCommercialLineTotalMinor(
        line.quantity,
        line.unitPriceMinor
      );

    if (
      total >
      MAX_SERVICE_ORDER_MONEY_MINOR
    ) {
      throw new RangeError(
        'Commercial total exceeds ServiceOrder DECIMAL(10,2)'
      );
    }
  }

  return total;
}

function compareSemanticLines(
  left:
    CommercialSemanticLine,
  right:
    CommercialSemanticLine
): number {
  return JSON
    .stringify(
      left
    )
    .localeCompare(
      JSON.stringify(
        right
      )
    );
}

/**
 * IDs are intentionally excluded.
 *
 * A regenerated technical row ID does not itself change what
 * the customer is being charged for or what scope was quoted.
 */
export function commercialScopeFingerprint(
  scope:
    CommercialSemanticScope
): string {
  const normalized = {
    diagnosis:
      scope.diagnosis,

    totalAmountMinor:
      scope.totalAmountMinor,

    items:
      [
        ...scope.items,
      ]
        .sort(
          compareSemanticLines
        ),
  };

  return computeCanonicalHash(
    normalized
  );
}
