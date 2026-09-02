const ALWAYS_BLOCKED_FIN_F02_GENERIC_SYNC_TYPES =
  new Set<string>([
    'RECEIVABLE',
    'RECEIVABLE_SCHEDULE',
    'RECEIVABLE_INSTALLMENT',
    'PAYMENT_ALLOCATION',
    'FINANCIAL_AUDIT_EVENT',
    'SERVICE_ORDER_QUOTE_REVISION',
    'CUSTOMER_QUOTE_DECISION',
  ]);

const GENERIC_SYNC_PULL_NON_FINANCE_ALLOWLIST =
  new Set<string>([
    'CUSTOMER',
    'EQUIPMENT',
    'SERVICE_ORDER',
    'SERVICE_ORDER_ITEM',
    'PART',
  ]);

function normalizeEntityType(
  entityType:
    string
): string {
  return entityType
    .toUpperCase();
}

/**
 * Generic Sync must never become a Finance Core mutation surface.
 *
 * PAYMENT is shared with legacy FIN-F01, but generic PAYMENT Push was
 * already forbidden there and remains forbidden for every Finance version.
 */
export function isGenericFinanceSyncPushBlocked(
  entityType:
    string
): boolean {
  const normalized =
    normalizeEntityType(
      entityType
    );

  return normalized ===
    'PAYMENT' ||
    ALWAYS_BLOCKED_FIN_F02_GENERIC_SYNC_TYPES
      .has(
        normalized
      );
}

export function isAlwaysBlockedFinF02FinanceSyncType(
  entityType:
    string
): boolean {
  return ALWAYS_BLOCKED_FIN_F02_GENERIC_SYNC_TYPES
    .has(
      normalizeEntityType(
        entityType
      )
    );
}

export type GenericServiceOrderDeleteAuthorityInput = {
  financeCoreVersion:
    number |
    null;

  currentQuoteRevisionId:
    string |
    null;
};

/**
 * FIN-F02 ServiceOrder deletion is never a generic Sync command.
 *
 * Legacy ServiceOrder deletion behavior is preserved only while the row has
 * never entered a versioned Finance Core and has no immutable quote pointer.
 *
 * Any non-null financeCoreVersion fails closed, including unknown future
 * versions.
 */
export function isGenericServiceOrderDeleteBlocked(
  input:
    GenericServiceOrderDeleteAuthorityInput
): boolean {
  return (
    input.financeCoreVersion !==
      null ||
    Boolean(
      input.currentQuoteRevisionId
    )
  );
}

export type GenericSyncPullAuthorizationInput = {
  entityType:
    string;

  role:
    string;

  /**
   * PAYMENT is the only shared legacy/F02 entity type.
   *
   * true means:
   * - current authenticated staff owns the Payment through tenant authority;
   * - its ServiceOrder is legacy (financeCoreVersion === null).
   */
  isAuthorizedLegacyPayment:
    boolean;
};

/**
 * Fail-closed Pull classifier.
 *
 * Non-finance generic Sync types are allowlisted explicitly.
 * Unknown types are denied even when entityId collides with an authorized
 * Customer/Equipment/ServiceOrder/etc.
 *
 * PAYMENT:
 * - CUSTOMER: always denied (FIN-F01 invariant);
 * - ADMIN/TECH: only an actually-owned legacy Payment is allowed;
 * - FIN-F02 Payment is denied.
 */
export function isGenericSyncPullTypeAllowed(
  input:
    GenericSyncPullAuthorizationInput
): boolean {
  const normalized =
    normalizeEntityType(
      input.entityType
    );

  if (
    ALWAYS_BLOCKED_FIN_F02_GENERIC_SYNC_TYPES
      .has(
        normalized
      )
  ) {
    return false;
  }

  if (
    normalized ===
    'PAYMENT'
  ) {
    return (
      input.role !==
        'CUSTOMER' &&
      input
        .isAuthorizedLegacyPayment
    );
  }

  return GENERIC_SYNC_PULL_NON_FINANCE_ALLOWLIST
    .has(
      normalized
    );
}
