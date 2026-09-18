# FE03-BE-P01 — prerequisite Backend commands

Baseline: `5880d19033d0e8c874438d9afe300806b030e231`.
Scope: CUSTOMER actionable quote read, CUSTOMER decision response minimization, dedicated settled delivery. No Flutter, Prisma schema/migration or dependency changes.

## CUSTOMER quote

`GET /api/v1/service-orders/:id/customer-quote` requires authenticated, live CUSTOMER ownership. Staff cannot use this endpoint. The transactional read uses the existing Sync barrier and validates current/prior quote identities, snapshot/hash, materialization and exact money before serialization.

Response:

```json
{
  "serviceOrderId": "uuid",
  "quote": {
    "quoteRevisionId": "uuid",
    "revisionNumber": 1,
    "decisionMode": "INITIAL_APPROVAL",
    "diagnosis": "Diagnosis",
    "items": [{"description": "Labor", "quantity": 2, "unitPriceMinor": 1234, "totalPriceMinor": 2468}],
    "totalAmountMinor": 2468,
    "changeReason": "Initial quote",
    "createdAt": "2026-09-18T00:00:00.000Z"
  }
}
```

`decisionMode` can also be `REAPPROVAL`. Diagnosis/changeReason are nullable. The explicit action selector does not add quote pointers to the generic CUSTOMER projection. Nonowned/missing orders return 404 `SERVICE_ORDER_NOT_FOUND`; owned unavailable states return 409 `CUSTOMER_QUOTE_NOT_ACTIONABLE`; corrupt history returns `CUSTOMER_QUOTE_HISTORY_INVALID`; decided revisions return `QUOTE_REVISION_ALREADY_DECIDED`.

FIN-F02 `POST /:id/quote-decision` keeps its input/header unchanged. Its public successful response is now `{serviceOrderId,status,quoteDecision:{quoteRevisionId,decision,reason,decidedAt}}`. Fresh responses and historical replays pass through the same allowlist. Persisted response bodies, request hashes and operation identities are unchanged. Malformed replay bodies fail closed. Legacy quote decisions retain their existing contract.

## Settled delivery

`POST /api/v1/service-orders/:id/mark-delivered`, ADMIN/TECHNICIAN, exact single UUID `X-Operation-Id`, strict body `{notes?: string}` (trimmed, 1–1000 characters).

Requires a FIN-F02 order in PRONTO, valid materialized approved quote and exactly one coherent ACTIVE receivable, whose confirmed allocations fully settle its positive exact total. Current schedule/installed amounts, scope of every allocation/payment, confirmation state and sums per payment/installment are validated. Pending payments do not prove settlement. Cancelled or contradictory allocated payments fail closed.

Lock order is the existing Sync barrier → scoped ServiceOrder → Receivable → current Schedule → current Installments → Payments → allocation reads. Status ENTREGUE, history, CRM completion, financial audit, observed canonical Sync event and idempotency completion commit together. No Payment/Receivable writes are performed by delivery.

Success: HTTP 200 `{order:{id,status:"ENTREGUE",customerId,organizationId}}` (staff only). Client must refresh `/api/v1/service-orders/:id/projection` after success and apply the canonical aggregate/revision. Retry uncertain results with the SAME operationId. A deterministic persisted failure still replays after the underlying financial state changes; a genuinely new intent requires a new operationId.

409 errors include `DELIVERY_STATUS_CONFLICT`, `FIN_F02_ORDER_REQUIRED`, `DELIVERY_QUOTE_HISTORY_INVALID`, `DELIVERY_FINANCIAL_INTEGRITY_INVALID`, `DELIVERY_REQUIRES_SETTLED_RECEIVABLE` and the existing idempotency errors. Nonowned/missing order: 404. Generic PATCH and Sync cannot perform FIN-F02 PRONTO → ENTREGUE. Legacy delivery remains supported; FIN-F02 generic cancellation remains blocked.

## Demo compatibility

The delivered demo scenario now creates/confirms its payment through dedicated REST commands and calls mark-delivered. Other demo money authorities are unchanged. New step operationIds do not reuse the old generic-delivery identity. The seed refuses a DB containing the previous demo delivery operation before creating identities or commands; use a fresh disposable demo environment. No seed was run during this implementation.

## Validation / remaining gate

TypeScript build and 114 pure/regression rule tests passed with Node 24.19.0 / npm 11.9.0. The project requires Node >=24.20.0 <25 and npm 11.19.0: repeat the required gate with those versions. This execution environment has no MySQL server and no DATABASE_URL. Therefore new MySQL tests, the FE-02B MySQL regression and the full backend suite are **not executed**, and no release/merge approval is asserted.

New DB tests cover quote ownership/privacy, initial/reapproval reads, corrupt history, historical replay minimization, unpaid/partial delivery, generic writer firewall, settled success, replay/conflicting intents, concurrent commands, transaction rollback and stale membership. Existing C7 tests now use Payment confirmation and mark-delivered. Database test fixtures deliberately keep immutable financial history until the whole disposable database is removed.

Using a separately provisioned disposable MySQL database (never the demo or primary database), set DATABASE_URL privately in your terminal, then run inside backend:

```powershell
npm.cmd ci
npm.cmd run prisma:generate
npx.cmd --no-install prisma migrate deploy
npm.cmd run build
node --test --test-concurrency=1 dist/modules/service_order_finance/fe03_be_p01.integration.test.js dist/modules/sync/sync.fe02b.integration.test.js
node --test --test-concurrency=1 'dist/**/*.test.js'
git diff --check
```

Use a fresh disposable database for the full suite if running gates independently. Docker is not required. Record candidate SHA/tree, exact commands, versions and results, without credentials. Submit this exact delta and gate evidence to Cyber before merge. No push/merge/deployment is included.
