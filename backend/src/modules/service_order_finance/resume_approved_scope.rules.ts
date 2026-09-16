import { checkedMinor, DECIMAL_10_2_MAX_MINOR, MAX_QUANTITY } from '../../core/money/money.js';
import { Prisma } from '@prisma/client';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  calculateCommercialLineTotalMinor,
  decimalTextToMinor,
} from './commercial_quote_revision.rules.js';

export type ApprovedScopeRestoreItem = {
  id: string;
  partId: string | null;
  description: string;
  quantity: number;
  unitPrice: string;
  totalPrice: string;
};

export type ApprovedScopeRestorePlan = {
  diagnosis: string | null;
  totalAmount: string;
  items: ApprovedScopeRestoreItem[];
};

export function parseApprovedQuoteSnapshotForResume(
  revision: {
    serviceOrderId: string;
    organizationId: string;
    customerId: string;
    quoteSnapshot: Prisma.JsonValue;
    quoteHash: string;
  }
): ApprovedScopeRestorePlan {
  if (
    computeCanonicalHash(
      revision.quoteSnapshot
    ) !== revision.quoteHash
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_HASH_MISMATCH'
    );
  }

  const raw =
    revision.quoteSnapshot;

  if (
    !raw ||
    typeof raw !== 'object' ||
    Array.isArray(raw)
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_SNAPSHOT_INVALID'
    );
  }

  const snapshot =
    raw as Record<string, unknown>;

  if (
    (snapshot.snapshotVersion !== 1 && snapshot.snapshotVersion !== 2) ||
    snapshot.serviceOrderId !== revision.serviceOrderId ||
    snapshot.organizationId !== revision.organizationId ||
    snapshot.customerId !== revision.customerId
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_IDENTITY_MISMATCH'
    );
  }

  if (
    snapshot.diagnosis !== null &&
    typeof snapshot.diagnosis !== 'string'
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_DIAGNOSIS_INVALID'
    );
  }

  if (
    typeof snapshot.totalAmount !== 'string'
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_TOTAL_INVALID'
    );
  }

  const totalMinor =
    decimalTextToMinor(
      snapshot.totalAmount
    );

  checkedMinor(totalMinor, DECIMAL_10_2_MAX_MINOR);
  if (totalMinor <= 0n) {
    throw new RangeError(
      'APPROVED_QUOTE_TOTAL_INVALID'
    );
  }

  if (
    !Array.isArray(snapshot.serviceItems) ||
    snapshot.serviceItems.length === 0
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_ITEMS_INVALID'
    );
  }

  if (snapshot.snapshotVersion === 2 && (!Array.isArray(snapshot.parts) || snapshot.parts.length !== 0)) {
    throw new RangeError('QUOTE_V2_GLOBAL_PART_AUTHORITY_FORBIDDEN');
  }
  const items: ApprovedScopeRestoreItem[] = [];
  let aggregateMinor = 0n;

  for (const rawItem of snapshot.serviceItems) {
    if (
      !rawItem ||
      typeof rawItem !== 'object' ||
      Array.isArray(rawItem)
    ) {
      throw new RangeError(
        'APPROVED_QUOTE_ITEM_INVALID'
      );
    }

    const item =
      rawItem as Record<string, unknown>;

    if (
      typeof item.id !== 'string' ||
      (
        item.partId !== null &&
        typeof item.partId !== 'string'
      ) ||
      typeof item.description !== 'string' ||
      !Number.isSafeInteger(item.quantity) ||
      (item.quantity as number) < 1 || (item.quantity as number) > MAX_QUANTITY ||
      typeof item.unitPrice !== 'string' ||
      typeof item.totalPrice !== 'string'
    ) {
      throw new RangeError(
        'APPROVED_QUOTE_ITEM_INVALID'
      );
    }

    const unitMinor =
      decimalTextToMinor(
        item.unitPrice
      );

    const totalLineMinor =
      decimalTextToMinor(
        item.totalPrice
      );

    const calculatedLineMinor =
      calculateCommercialLineTotalMinor(
        item.quantity as number,
        checkedMinor(unitMinor, DECIMAL_10_2_MAX_MINOR)
      );

    if (
      calculatedLineMinor !==
      totalLineMinor
    ) {
      throw new RangeError(
        'APPROVED_QUOTE_LINE_TOTAL_MISMATCH'
      );
    }

    aggregateMinor +=
      totalLineMinor;

    items.push({
      id:
        item.id,
      partId:
        item.partId as string | null,
      description:
        item.description,
      quantity:
        item.quantity as number,
      unitPrice:
        item.unitPrice,
      totalPrice:
        item.totalPrice,
    });
  }

  if (
    new Set(
      items.map((item) => item.id)
    ).size !== items.length
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_DUPLICATE_ITEM_ID'
    );
  }

  if (
    aggregateMinor !== totalMinor
  ) {
    throw new RangeError(
      'APPROVED_QUOTE_AGGREGATE_TOTAL_MISMATCH'
    );
  }

  return {
    diagnosis:
      snapshot.diagnosis as string | null,
    totalAmount:
      snapshot.totalAmount,
    items,
  };
}
