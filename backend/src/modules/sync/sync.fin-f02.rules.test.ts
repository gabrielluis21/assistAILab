import test from 'node:test';
import assert from 'node:assert/strict';

import {
  isAlwaysBlockedFinF02FinanceSyncType,
  isGenericFinanceSyncPushBlocked,
  isGenericSyncPullTypeAllowed,
  isGenericServiceOrderDeleteBlocked,
} from './sync.fin-f02.rules.js';

test(
  'FIN-F02 generic Sync Push blocks every Finance Core entity while keeping ServiceOrder outside the finance entity firewall',
  () => {
    for (
      const entityType of
      [
        'PAYMENT',
        'payment',
        'RECEIVABLE',
        'RECEIVABLE_SCHEDULE',
        'RECEIVABLE_INSTALLMENT',
        'PAYMENT_ALLOCATION',
        'FINANCIAL_AUDIT_EVENT',
        'SERVICE_ORDER_QUOTE_REVISION',
        'CUSTOMER_QUOTE_DECISION',
      ]
    ) {
      assert.equal(
        isGenericFinanceSyncPushBlocked(
          entityType
        ),
        true,
        entityType
      );
    }

    assert.equal(
      isGenericFinanceSyncPushBlocked(
        'SERVICE_ORDER'
      ),
      false
    );

    assert.equal(
      isGenericFinanceSyncPushBlocked(
        'SERVICE_ORDER_ITEM'
      ),
      false
    );
  }
);

test(
  'FIN-F02 Pull allowlist fails closed for Finance Core and unknown entity types even on authorized-id collision',
  () => {
    for (
      const entityType of
      [
        'RECEIVABLE',
        'RECEIVABLE_SCHEDULE',
        'RECEIVABLE_INSTALLMENT',
        'PAYMENT_ALLOCATION',
        'FINANCIAL_AUDIT_EVENT',
        'SERVICE_ORDER_QUOTE_REVISION',
        'CUSTOMER_QUOTE_DECISION',
        'SOMETHING_UNKNOWN',
      ]
    ) {
      assert.equal(
        isGenericSyncPullTypeAllowed({
          entityType,
          role:
            'ADMIN',
          isAuthorizedLegacyPayment:
            true,
        }),
        false,
        entityType
      );
    }
  }
);

test(
  'FIN-F01 compatibility keeps only owned legacy Payment Pull for staff and denies Payment to CUSTOMER',
  () => {
    assert.equal(
      isGenericSyncPullTypeAllowed({
        entityType:
          'PAYMENT',
        role:
          'ADMIN',
        isAuthorizedLegacyPayment:
          true,
      }),
      true
    );

    assert.equal(
      isGenericSyncPullTypeAllowed({
        entityType:
          'PAYMENT',
        role:
          'TECHNICIAN',
        isAuthorizedLegacyPayment:
          true,
      }),
      true
    );

    assert.equal(
      isGenericSyncPullTypeAllowed({
        entityType:
          'PAYMENT',
        role:
          'ADMIN',
        isAuthorizedLegacyPayment:
          false,
      }),
      false
    );

    assert.equal(
      isGenericSyncPullTypeAllowed({
        entityType:
          'PAYMENT',
        role:
          'CUSTOMER',
        isAuthorizedLegacyPayment:
          true,
      }),
      false
    );
  }
);

test(
  'non-finance generic Sync Pull types remain explicitly allowlisted',
  () => {
    for (
      const entityType of
      [
        'CUSTOMER',
        'EQUIPMENT',
        'SERVICE_ORDER',
        'SERVICE_ORDER_ITEM',
        'PART',
      ]
    ) {
      assert.equal(
        isGenericSyncPullTypeAllowed({
          entityType,
          role:
            'ADMIN',
          isAuthorizedLegacyPayment:
            false,
        }),
        true,
        entityType
      );
    }
  }
);

test(
  'canonical FIN-F02 finance type classifier is case-insensitive',
  () => {
    assert.equal(
      isAlwaysBlockedFinF02FinanceSyncType(
        'receivable'
      ),
      true
    );

    assert.equal(
      isAlwaysBlockedFinF02FinanceSyncType(
        'SERVICE_ORDER'
      ),
      false
    );
  }
);


test(
  'FIN-F02 generic ServiceOrder DELETE is blocked for versioned/published orders while untouched legacy behavior remains distinct',
  () => {
    assert.equal(
      isGenericServiceOrderDeleteBlocked({
        financeCoreVersion:
          2,
        currentQuoteRevisionId:
          null,
      }),
      true
    );

    assert.equal(
      isGenericServiceOrderDeleteBlocked({
        financeCoreVersion:
          3,
        currentQuoteRevisionId:
          null,
      }),
      true
    );

    assert.equal(
      isGenericServiceOrderDeleteBlocked({
        financeCoreVersion:
          null,
        currentQuoteRevisionId:
          'published-quote-id',
      }),
      true
    );

    assert.equal(
      isGenericServiceOrderDeleteBlocked({
        financeCoreVersion:
          null,
        currentQuoteRevisionId:
          null,
      }),
      false
    );
  }
);
