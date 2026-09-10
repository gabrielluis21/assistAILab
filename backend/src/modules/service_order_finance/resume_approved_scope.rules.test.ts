import test from 'node:test';
import assert from 'node:assert/strict';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  parseApprovedQuoteSnapshotForResume,
} from './resume_approved_scope.rules.js';

function fixture() {
  const quoteSnapshot = {
    snapshotVersion:
      1,
    serviceOrderId:
      'so-1',
    organizationId:
      'org-1',
    customerId:
      'customer-1',
    diagnosis:
      'Approved diagnosis',
    totalAmount:
      '150.00',
    serviceItems: [
      {
        id:
          'item-1',
        partId:
          null,
        description:
          'Labor',
        quantity:
          1,
        unitPrice:
          '100.00',
        totalPrice:
          '100.00',
      },
      {
        id:
          'item-2',
        partId:
          'part-1',
        description:
          'Part',
        quantity:
          1,
        unitPrice:
          '50.00',
        totalPrice:
          '50.00',
      },
    ],
    parts:
      [],
  };

  return {
    serviceOrderId:
      'so-1',
    organizationId:
      'org-1',
    customerId:
      'customer-1',
    quoteSnapshot,
    quoteHash:
      computeCanonicalHash(
        quoteSnapshot
      ),
  };
}

test(
  'FIN-F02 resume parser accepts coherent approved snapshot',
  () => {
    const result =
      parseApprovedQuoteSnapshotForResume(
        fixture()
      );

    assert.equal(
      result.totalAmount,
      '150.00'
    );

    assert.equal(
      result.items.length,
      2
    );
  }
);

test(
  'FIN-F02 resume parser rejects hash mismatch',
  () => {
    const value =
      fixture();

    assert.throws(
      () =>
        parseApprovedQuoteSnapshotForResume({
          ...value,
          quoteHash:
            '0'.repeat(64),
        }),
      /APPROVED_QUOTE_HASH_MISMATCH/
    );
  }
);

test(
  'FIN-F02 resume parser rejects line total mismatch',
  () => {
    const value =
      fixture();

    const quoteSnapshot = {
      ...value.quoteSnapshot,
      serviceItems: [
        {
          ...value.quoteSnapshot
            .serviceItems[0],
          totalPrice:
            '99.99',
        },
        value.quoteSnapshot
          .serviceItems[1],
      ],
    };

    assert.throws(
      () =>
        parseApprovedQuoteSnapshotForResume({
          ...value,
          quoteSnapshot,
          quoteHash:
            computeCanonicalHash(
              quoteSnapshot
            ),
        }),
      /APPROVED_QUOTE_LINE_TOTAL_MISMATCH/
    );
  }
);

test(
  'FIN-F02 resume parser rejects aggregate mismatch',
  () => {
    const value =
      fixture();

    const quoteSnapshot = {
      ...value.quoteSnapshot,
      totalAmount:
        '160.00',
    };

    assert.throws(
      () =>
        parseApprovedQuoteSnapshotForResume({
          ...value,
          quoteSnapshot,
          quoteHash:
            computeCanonicalHash(
              quoteSnapshot
            ),
        }),
      /APPROVED_QUOTE_AGGREGATE_TOTAL_MISMATCH/
    );
  }
);
