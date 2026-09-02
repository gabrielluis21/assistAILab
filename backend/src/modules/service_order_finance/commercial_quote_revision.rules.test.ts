import test from 'node:test';
import assert from 'node:assert/strict';

import {
  calculateCommercialLineTotalMinor,
  calculateCommercialTotalMinor,
  commercialScopeFingerprint,
  decimalTextToMinor,
  moneyMinorToDecimalText,
} from './commercial_quote_revision.rules.js';

test(
  'FIN-F02 commercial money converts minor units without floating point',
  () => {
    assert.equal(
      moneyMinorToDecimalText(
        1n
      ),
      '0.01'
    );

    assert.equal(
      moneyMinorToDecimalText(
        105n
      ),
      '1.05'
    );

    assert.equal(
      decimalTextToMinor(
        '123.45'
      ),
      12345n
    );
  }
);

test(
  'FIN-F02 commercial line and aggregate totals use integer minor units',
  () => {
    assert.equal(
      calculateCommercialLineTotalMinor(
        3,
        1999
      ),
      5997n
    );

    assert.equal(
      calculateCommercialTotalMinor([
        {
          quantity:
            2,
          unitPriceMinor:
            2500,
        },
        {
          quantity:
            1,
          unitPriceMinor:
            1000,
        },
      ]),
      6000n
    );
  }
);

test(
  'FIN-F02 semantic fingerprint ignores row ordering',
  () => {
    const left =
      commercialScopeFingerprint({
        diagnosis:
          'A',
        totalAmountMinor:
          3000,
        items: [
          {
            partId:
              null,
            description:
              'Labor',
            quantity:
              1,
            unitPriceMinor:
              1000,
            totalPriceMinor:
              1000,
          },
          {
            partId:
              'part-x',
            description:
              'Part',
            quantity:
              1,
            unitPriceMinor:
              2000,
            totalPriceMinor:
              2000,
          },
        ],
      });

    const right =
      commercialScopeFingerprint({
        diagnosis:
          'A',
        totalAmountMinor:
          3000,
        items: [
          {
            partId:
              'part-x',
            description:
              'Part',
            quantity:
              1,
            unitPriceMinor:
              2000,
            totalPriceMinor:
              2000,
          },
          {
            partId:
              null,
            description:
              'Labor',
            quantity:
              1,
            unitPriceMinor:
              1000,
            totalPriceMinor:
              1000,
          },
        ],
      });

    assert.equal(
      left,
      right
    );
  }
);

test(
  'FIN-F02 semantic fingerprint changes for actual commercial changes',
  () => {
    const base = {
      diagnosis:
        'A',
      totalAmountMinor:
        1000,
      items: [
        {
          partId:
            null,
          description:
            'Labor',
          quantity:
            1,
          unitPriceMinor:
            1000,
          totalPriceMinor:
            1000,
        },
      ],
    };

    assert.notEqual(
      commercialScopeFingerprint(
        base
      ),
      commercialScopeFingerprint({
        ...base,
        diagnosis:
          'B',
      })
    );
  }
);
