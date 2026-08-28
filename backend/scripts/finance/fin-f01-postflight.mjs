import { PrismaClient } from '@prisma/client';
import {
  FinF01State,
  inspectFinF01Lifecycle,
  jsonReplacer,
} from './fin-f01-lifecycle.mjs';

const prisma = new PrismaClient();
const immediate = process.argv.includes('--immediate');

try {
  const lifecycle = await inspectFinF01Lifecycle(prisma);

  if (lifecycle.state !== FinF01State.POST_MIGRATION) {
    console.log(JSON.stringify({
      gate: 'FIN-F01-POSTFLIGHT',
      mode: immediate ? 'IMMEDIATE' : 'HEALTH',
      ...lifecycle,
      integrity: null,
      result: 'FAIL',
      note: 'Fail-closed: postflight requires POST_MIGRATION lifecycle state. No post-schema Payment integrity query was executed.',
    }, jsonReplacer, 2));
    process.exitCode = 2;
  } else {
    const integrity = await prisma.$queryRawUnsafe(`
      SELECT
        COUNT(*) AS payment_count,
        SUM(so.id IS NULL) AS orphan_service_order_count,
        SUM(p.organizationId IS NULL) AS null_tenant_count,
        SUM(p.clientOperationId IS NULL) AS null_operation_count,
        SUM(so.id IS NOT NULL AND p.organizationId <> so.organizationId)
          AS tenant_mismatch_count,
        SUM(so.id IS NOT NULL AND p.customerId <> so.customerId)
          AS customer_mismatch_count,
        COUNT(DISTINCT p.clientOperationId) AS distinct_operation_count,
        SUM(p.status = 'REFUNDED') AS legacy_refunded_count
      FROM payments p
      LEFT JOIN service_orders so
        ON so.id = p.serviceOrderId
    `);

    const row = integrity[0];
    const paymentCount = Number(row.payment_count ?? 0);
    let immediateRatification = null;

    if (immediate) {
      const ratification = await prisma.$queryRawUnsafe(`
        SELECT
          SUM(p.createdByUserId IS NULL) AS ratified_legacy_history_count,
          SUM(
            p.createdByUserId IS NULL
            AND p.clientOperationId <> CONCAT('legacy:', p.id)
          ) AS legacy_operation_id_mismatch_count,
          SUM(
            p.createdByUserId IS NULL
            AND p.version <> 1
          ) AS legacy_version_mismatch_count
        FROM payments p
      `);
      immediateRatification = ratification[0];
    }

    const commonPass =
      Number(row.orphan_service_order_count ?? 0) === 0 &&
      Number(row.null_tenant_count ?? 0) === 0 &&
      Number(row.null_operation_count ?? 0) === 0 &&
      Number(row.tenant_mismatch_count ?? 0) === 0 &&
      Number(row.customer_mismatch_count ?? 0) === 0 &&
      Number(row.distinct_operation_count ?? 0) === paymentCount;

    const immediatePass =
      !immediate ||
      (
        Number(immediateRatification?.legacy_operation_id_mismatch_count ?? 0) === 0 &&
        Number(immediateRatification?.legacy_version_mismatch_count ?? 0) === 0
      );

    const pass = commonPass && immediatePass;

    console.log(JSON.stringify({
      gate: 'FIN-F01-POSTFLIGHT',
      mode: immediate ? 'IMMEDIATE' : 'HEALTH',
      ...lifecycle,
      integrity: row,
      immediateRatification,
      result: pass ? 'PASS' : 'FAIL',
      note: immediate
        ? 'Immediate post-migration gate: run before enabling financial writers. legacy:<paymentId> and version=1 ratification are mandatory only in this mode.'
        : 'Permanent post-migration health gate: validates tenant/customer authority, orphan absence, operation uniqueness and structural lifecycle state. version=1 is intentionally not a permanent invariant.',
    }, jsonReplacer, 2));

    if (!pass) process.exitCode = 2;
  }
} finally {
  await prisma.$disconnect();
}
