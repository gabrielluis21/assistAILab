import {
  Prisma,
} from '@prisma/client';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  organizationLocalCivilDate,
} from '../../core/time/organization_time.js';

import {
  calculateCommercialLineTotalMinor,
  commercialScopeFingerprint,
  decimalTextToMinor,
  type CommercialSemanticLine,
  type CommercialSemanticScope,
} from './commercial_quote_revision.rules.js';

export type ApprovedQuoteAuthority = {
  commercialScope:
    CommercialSemanticScope;

  totalAmount:
    string;
};

export type InitialReceivablePlan = {
  totalAmount:
    string;

  issuedAt:
    Date;

  scheduleVersion:
    1;

  installment: {
    sequence:
      1;

    amount:
      string;

    dueDate:
      Date;
  };
};

export function approvedQuoteAuthorityFromRevision(
  revision: {
    serviceOrderId:
      string;

    organizationId:
      string;

    customerId:
      string;

    diagnosisSnapshot:
      string |
      null;

    serviceItemsSnapshot:
      Prisma.JsonValue;

    totalAmount:
      Prisma.Decimal;

    quoteSnapshot:
      Prisma.JsonValue;

    quoteHash:
      string;
  }
): ApprovedQuoteAuthority {
  if (
    computeCanonicalHash(
      revision.quoteSnapshot
    ) !==
    revision.quoteHash
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_HASH_MISMATCH'
    );
  }

  if (
    !revision.quoteSnapshot ||
    typeof revision.quoteSnapshot !==
      'object' ||
    Array.isArray(
      revision.quoteSnapshot
    )
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_SNAPSHOT_INVALID'
    );
  }

  const snapshot =
    revision.quoteSnapshot as
      Record<
        string,
        unknown
      >;

  const totalAmount =
    revision.totalAmount
      .toFixed(2);

  if (
    snapshot.snapshotVersion !==
      1 ||
    snapshot.serviceOrderId !==
      revision.serviceOrderId ||
    snapshot.organizationId !==
      revision.organizationId ||
    snapshot.customerId !==
      revision.customerId ||
    snapshot.diagnosis !==
      revision.diagnosisSnapshot ||
    snapshot.totalAmount !==
      totalAmount
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_SNAPSHOT_IDENTITY_MISMATCH'
    );
  }

  if (
    computeCanonicalHash(
      snapshot.serviceItems
    ) !==
    computeCanonicalHash(
      revision.serviceItemsSnapshot
    )
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_ITEMS_SNAPSHOT_MISMATCH'
    );
  }

  if (
    !Array.isArray(
      revision
        .serviceItemsSnapshot
    )
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_ITEMS_INVALID'
    );
  }

  const items:
    CommercialSemanticLine[] =
      [];

  for (
    const rawItem of
    revision
      .serviceItemsSnapshot
  ) {
    if (
      !rawItem ||
      typeof rawItem !==
        'object' ||
      Array.isArray(
        rawItem
      )
    ) {
      throw new RangeError(
        'APPROVED_QUOTE_ITEM_INVALID'
      );
    }

    const item =
      rawItem as
        Record<
          string,
          unknown
        >;

    if (
      (
        item.partId !==
          null &&
        typeof item.partId !==
          'string'
      ) ||
      typeof item.description !==
        'string' ||
      !Number.isSafeInteger(
        item.quantity
      ) ||
      (
        item.quantity as
          number
      ) <
        1 ||
      typeof item.unitPrice !==
        'string' ||
      typeof item.totalPrice !==
        'string'
    ) {
      throw new RangeError(
        'APPROVED_QUOTE_ITEM_INVALID'
      );
    }

    const unitMinor =
      decimalTextToMinor(
        item.unitPrice
      );

    const lineMinor =
      decimalTextToMinor(
        item.totalPrice
      );

    if (
      calculateCommercialLineTotalMinor(
        item.quantity as
          number,
        Number(
          unitMinor
        )
      ) !==
      lineMinor
    ) {
      throw new RangeError(
        'APPROVED_QUOTE_LINE_TOTAL_MISMATCH'
      );
    }

    items.push({
      partId:
        item.partId as
          string |
          null,

      description:
        item.description,

      quantity:
        item.quantity as
          number,

      unitPriceMinor:
        Number(
          unitMinor
        ),

      totalPriceMinor:
        Number(
          lineMinor
        ),
    });
  }

  const totalAmountMinor =
    decimalTextToMinor(
      totalAmount
    );

  if (
    totalAmountMinor <=
    0n
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_TOTAL_MUST_BE_POSITIVE'
    );
  }

  return {
    totalAmount,

    commercialScope: {
      diagnosis:
        revision
          .diagnosisSnapshot,

      totalAmountMinor:
        Number(
          totalAmountMinor
        ),

      items,
    },
  };
}

export function liveCommercialScopeFingerprint(
  order: {
    diagnosis:
      string |
      null;

    totalAmount:
      Prisma.Decimal;

    items:
      Array<{
        partId:
          string |
          null;

        description:
          string;

        quantity:
          number;

        unitPrice:
          Prisma.Decimal;

        totalPrice:
          Prisma.Decimal;
      }>;
  }
): string {
  const scope:
    CommercialSemanticScope = {
      diagnosis:
        order.diagnosis,

      totalAmountMinor:
        Number(
          decimalTextToMinor(
            order
              .totalAmount
              .toFixed(2)
          )
        ),

      items:
        order.items.map(
          (
            item
          ) => ({
            partId:
              item.partId,

            description:
              item.description,

            quantity:
              item.quantity,

            unitPriceMinor:
              Number(
                decimalTextToMinor(
                  item
                    .unitPrice
                    .toFixed(2)
                )
              ),

            totalPriceMinor:
              Number(
                decimalTextToMinor(
                  item
                    .totalPrice
                    .toFixed(2)
                )
              ),
          })
        ),
    };

  return commercialScopeFingerprint(
    scope
  );
}

export function buildInitialReceivablePlan(
  totalAmount:
    string,
  issuedAt:
    Date,
  organizationTimeZone:
    string
): InitialReceivablePlan {
  const amountMinor =
    decimalTextToMinor(
      totalAmount
    );

  if (
    amountMinor <=
    0n
  ) {
    throw new RangeError(
      'Receivable total must be positive'
    );
  }

  return {
    totalAmount,
    issuedAt,
    scheduleVersion:
      1,
    installment: {
      sequence:
        1,
      amount:
        totalAmount,
      dueDate:
        organizationLocalCivilDate(
          issuedAt,
          organizationTimeZone
        ),
    },
  };
}
