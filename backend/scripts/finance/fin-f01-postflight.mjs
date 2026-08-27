import { PrismaClient } from '@prisma/client';

const prisma = new PrismaClient();

try {
  const migration = await prisma.$queryRawUnsafe(`
    SELECT migration_name, checksum, finished_at, rolled_back_at
    FROM _prisma_migrations
    WHERE migration_name =
      '20260827103000_fin_f01_legacy_payment_hardening'
  `);

  const integrity = await prisma.$queryRawUnsafe(`
    SELECT
      COUNT(*) AS payment_count,
      SUM(p.organizationId IS NULL) AS null_tenant_count,
      SUM(p.clientOperationId IS NULL) AS null_operation_count,
      SUM(p.organizationId <> so.organizationId) AS tenant_mismatch_count,
      SUM(p.customerId <> so.customerId) AS customer_mismatch_count,
      COUNT(DISTINCT p.clientOperationId) AS distinct_operation_count
    FROM payments p
    INNER JOIN service_orders so
      ON so.id = p.serviceOrderId
  `);

  const columns = await prisma.$queryRawUnsafe(`
    SELECT
      COLUMN_NAME AS columnName,
      COLUMN_TYPE AS columnType,
      IS_NULLABLE AS isNullable
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'payments'
      AND COLUMN_NAME IN (
        'organizationId',
        'clientOperationId',
        'amount',
        'createdByUserId',
        'confirmedByUserId',
        'cancelledByUserId',
        'cancelledAt',
        'version'
      )
    ORDER BY COLUMN_NAME
  `);

  const frozenTable = await prisma.$queryRawUnsafe(`
    SELECT COUNT(*) AS frozen_table_count
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = 'payments_fin_f01_write_frozen'
  `);

  const row = integrity[0];
  const paymentCount = Number(row.payment_count ?? 0);

  const pass =
    migration.length === 1 &&
    migration[0].finished_at !== null &&
    migration[0].rolled_back_at === null &&
    Number(row.null_tenant_count ?? 0) === 0 &&
    Number(row.null_operation_count ?? 0) === 0 &&
    Number(row.tenant_mismatch_count ?? 0) === 0 &&
    Number(row.customer_mismatch_count ?? 0) === 0 &&
    Number(row.distinct_operation_count ?? 0) === paymentCount &&
    Number(frozenTable[0]?.frozen_table_count ?? 0) === 0 &&
    columns.some(
      (column) =>
        column.columnName === 'amount' &&
        String(column.columnType).toLowerCase() === 'decimal(14,2)'
    );

  console.log(JSON.stringify({
    gate: 'FIN-F01-POSTFLIGHT',
    migration,
    integrity: row,
    columns,
    frozenTable: frozenTable[0],
    result: pass ? 'PASS' : 'FAIL',
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
