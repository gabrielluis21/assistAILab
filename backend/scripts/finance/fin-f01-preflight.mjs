import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

try {
  const db = await prisma.$queryRawUnsafe(
    'SELECT DATABASE() AS databaseName'
  );

  const h02 = await prisma.$queryRawUnsafe(`
    SELECT migration_name, checksum, finished_at, rolled_back_at
    FROM _prisma_migrations
    WHERE migration_name =
      '20260826164000_sec_f01_h02_lease_ownership'
  `);

  const failedMigrations = await prisma.$queryRawUnsafe(`
    SELECT migration_name, finished_at, rolled_back_at
    FROM _prisma_migrations
    WHERE finished_at IS NULL
      AND rolled_back_at IS NULL
  `);

  const integrity = await prisma.$queryRawUnsafe(`
    SELECT
      COUNT(*) AS payment_count,
      SUM(so.id IS NULL) AS orphan_service_order_count,
      SUM(
        so.id IS NOT NULL
        AND p.customerId <> so.customerId
      ) AS customer_authority_mismatch_count,
      SUM(p.status = 'REFUNDED') AS legacy_refunded_count
    FROM payments p
    LEFT JOIN service_orders so
      ON so.id = p.serviceOrderId
  `);

  const h02Rows = h02;
  const failedRows = failedMigrations;
  const integrityRow = integrity[0];

  const pass =
    h02Rows.length === 1 &&
    h02Rows[0].finished_at !== null &&
    h02Rows[0].rolled_back_at === null &&
    failedRows.length === 0 &&
    Number(integrityRow.orphan_service_order_count ?? 0) === 0;

  console.log(JSON.stringify({
    gate: 'FIN-F01-PREFLIGHT',
    database: db[0]?.databaseName ?? null,
    h02: h02Rows,
    failedMigrations: failedRows,
    integrity: integrityRow,
    result: pass ? 'PASS' : 'FAIL',
    note:
      'customer_authority_mismatch_count is informational: FIN-F01 migration repairs customerId from ServiceOrder authority. REFUNDED is legacy-read-only and preserved.',
  }, (_, value) =>
    typeof value === 'bigint'
      ? value.toString()
      : value,
  2));

  if (!pass) {
    process.exitCode = 2;
  }
} finally {
  await prisma.$disconnect();
}
