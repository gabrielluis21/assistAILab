import { PrismaClient } from '@prisma/client';
import {
  FinF01State,
  inspectFinF01Lifecycle,
  jsonReplacer,
} from './fin-f01-lifecycle.mjs';

const prisma = new PrismaClient();

try {
  const lifecycle = await inspectFinF01Lifecycle(prisma);

  if (lifecycle.state === FinF01State.INVALID_OR_PARTIAL) {
    console.log(JSON.stringify({
      gate: 'FIN-F01-PREFLIGHT',
      ...lifecycle,
      integrity: null,
      result: 'FAIL',
      note: 'Fail-closed: FIN-F01 lifecycle is invalid or partial. No schema-specific Payment query was executed.',
    }, jsonReplacer, 2));
    process.exitCode = 2;
  } else if (lifecycle.state === FinF01State.POST_MIGRATION) {
    console.log(JSON.stringify({
      gate: 'FIN-F01-PREFLIGHT',
      ...lifecycle,
      integrity: null,
      result: 'FAIL',
      note: 'Preflight must run only in PRE_MIGRATION state. This database is already POST_MIGRATION; use fin-f01-postflight.mjs instead.',
    }, jsonReplacer, 2));
    process.exitCode = 2;
  } else {
    const integrity = await prisma.$queryRawUnsafe(`
      SELECT
        COUNT(*) AS payment_count,
        SUM(so.id IS NULL) AS orphan_service_order_count,
        SUM(so.id IS NOT NULL AND p.customerId <> so.customerId)
          AS customer_authority_mismatch_count,
        SUM(p.status = 'REFUNDED') AS legacy_refunded_count
      FROM payments p
      LEFT JOIN service_orders so
        ON so.id = p.serviceOrderId
    `);

    const row = integrity[0];
    const pass =
      Number(row.orphan_service_order_count ?? 0) === 0 &&
      Number(row.customer_authority_mismatch_count ?? 0) === 0;

    console.log(JSON.stringify({
      gate: 'FIN-F01-PREFLIGHT',
      ...lifecycle,
      integrity: row,
      result: pass ? 'PASS' : 'FAIL',
      note: 'PRE_MIGRATION gate: exact H02 checksum, clean migration ledger, legacy Payment schema, zero orphan ServiceOrder and zero customer-authority mismatch are mandatory. REFUNDED is informational.',
    }, jsonReplacer, 2));

    if (!pass) process.exitCode = 2;
  }
} finally {
  await prisma.$disconnect();
}
