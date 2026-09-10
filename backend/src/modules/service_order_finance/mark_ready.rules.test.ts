import test from 'node:test';
import assert from 'node:assert/strict';

import {
  Prisma,
} from '@prisma/client';

import {
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  approvedQuoteAuthorityFromRevision,
  buildInitialReceivablePlan,
} from './mark_ready.rules.js';

function approvedRevisionFixture() {
  const serviceItemsSnapshot = [
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
        '150.00',
      totalPrice:
        '150.00',
    },
  ];

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
    serviceItems:
      serviceItemsSnapshot,
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
    diagnosisSnapshot:
      'Approved diagnosis',
    serviceItemsSnapshot,
    totalAmount:
      new Prisma.Decimal(
        '150.00'
      ),
    quoteSnapshot,
    quoteHash:
      computeCanonicalHash(
        quoteSnapshot
      ),
  };
}

test(
  'FIN-F02 MARK READY derives approved commercial authority from immutable quote',
  () => {
    const authority =
      approvedQuoteAuthorityFromRevision(
        approvedRevisionFixture()
      );

    assert.equal(
      authority.totalAmount,
      '150.00'
    );

    assert.equal(
      authority
        .commercialScope
        .totalAmountMinor,
      15000
    );
  }
);

test(
  'FIN-F02 MARK READY rejects approved quote hash mismatch',
  () => {
    const fixture =
      approvedRevisionFixture();

    assert.throws(
      () =>
        approvedQuoteAuthorityFromRevision({
          ...fixture,
          quoteHash:
            '0'.repeat(
              64
            ),
        }),
      /APPROVED_QUOTE_HASH_MISMATCH/
    );
  }
);

test(
  'FIN-F02 initial receivable uses one full-value installment due on organization-local issue date',
  () => {
    const issuedAt =
      new Date(
        '2026-09-01T02:30:00.000Z'
      );

    const plan =
      buildInitialReceivablePlan(
        '150.00',
        issuedAt,
        'America/Sao_Paulo'
      );

    assert.equal(
      plan.scheduleVersion,
      1
    );

    assert.equal(
      plan
        .installment
        .sequence,
      1
    );

    assert.equal(
      plan
        .installment
        .amount,
      '150.00'
    );

    assert.equal(
      plan
        .installment
        .dueDate
        .toISOString()
        .slice(
          0,
          10
        ),
      '2026-08-31'
    );
  }
);

test(
  'FIN-F02 initial receivable rejects non-positive approved amount',
  () => {
    assert.throws(
      () =>
        buildInitialReceivablePlan(
          '0.00',
          new Date(),
          'America/Sao_Paulo'
        ),
      /positive/
    );
  }
);
