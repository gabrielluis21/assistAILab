import { decimalMoneyText, decimalToMinorUnits, checkedMinor, DECIMAL_10_2_MAX_MINOR, aggregateTotalMinor, lineTotalMinor } from '../../core/money/money.js';
import { parseApprovedQuoteSnapshotForResume } from './resume_approved_scope.rules.js';
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
  const plan = parseApprovedQuoteSnapshotForResume(revision);
  const totalAmount = decimalMoneyText(revision.totalAmount, DECIMAL_10_2_MAX_MINOR);
  if (plan.diagnosis !== revision.diagnosisSnapshot || plan.totalAmount !== totalAmount ||
      computeCanonicalHash((revision.quoteSnapshot as Prisma.JsonObject).serviceItems) !== computeCanonicalHash(revision.serviceItemsSnapshot)) {
    throw new RangeError('APPROVED_QUOTE_SNAPSHOT_IDENTITY_MISMATCH');
  }
  return { totalAmount, commercialScope: {
    diagnosis: plan.diagnosis,
    totalAmountMinor: decimalToMinorUnits(revision.totalAmount, DECIMAL_10_2_MAX_MINOR),
    items: plan.items.map(item => ({
      partId: item.partId, description: item.description, quantity: item.quantity,
      unitPriceMinor: checkedMinor(decimalTextToMinor(item.unitPrice), DECIMAL_10_2_MAX_MINOR),
      totalPriceMinor: checkedMinor(decimalTextToMinor(item.totalPrice), DECIMAL_10_2_MAX_MINOR),
    })),
  } };

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
  const scope: CommercialSemanticScope = {
    diagnosis: order.diagnosis,
    totalAmountMinor: decimalToMinorUnits(order.totalAmount, DECIMAL_10_2_MAX_MINOR),
    items: order.items.map(item => ({
      partId: item.partId, description: item.description, quantity: item.quantity,
      unitPriceMinor: decimalToMinorUnits(item.unitPrice, DECIMAL_10_2_MAX_MINOR),
      totalPriceMinor: decimalToMinorUnits(item.totalPrice, DECIMAL_10_2_MAX_MINOR),
    })),
  };
  for (const item of scope.items) if (lineTotalMinor(item.quantity, item.unitPriceMinor) !== item.totalPriceMinor) {
    throw new RangeError('LIVE_QUOTE_LINE_TOTAL_MISMATCH');
  }
  if (aggregateTotalMinor(scope.items) !== scope.totalAmountMinor) throw new RangeError('LIVE_QUOTE_TOTAL_MISMATCH');
  return commercialScopeFingerprint(scope);

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
