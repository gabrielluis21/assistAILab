export const H02_MIGRATION =
  '20260826164000_sec_f01_h02_lease_ownership';

export const FIN_F01_MIGRATION =
  '20260827103000_fin_f01_legacy_payment_hardening';

export const APPROVED_H02_CHECKSUM =
  '8cb94477990bc640d3f416349372b644e7420c8fb835b6871e296b9399e2debf';

export const APPROVED_FIN_F01_CHECKSUM =
  '9d2f7d459eadb86e1fc52871e2b0cc361204cf933986af8ea99a5a80ac67973f';

export const FinF01State = Object.freeze({
  PRE_MIGRATION: 'PRE_MIGRATION',
  POST_MIGRATION: 'POST_MIGRATION',
  INVALID_OR_PARTIAL: 'INVALID_OR_PARTIAL',
});

const LEGACY_PAYMENT_COLUMNS = [
  'id', 'serviceOrderId', 'customerId', 'amount', 'method',
  'status', 'notes', 'paidAt', 'createdAt', 'updatedAt',
];

const FIN_F01_COLUMNS = [
  'organizationId', 'clientOperationId', 'createdByUserId',
  'confirmedByUserId', 'cancelledByUserId', 'cancelledAt', 'version',
];

function activeMigration(rows, checksum) {
  return rows.length === 1 &&
    rows[0].finished_at !== null &&
    rows[0].rolled_back_at === null &&
    rows[0].checksum === checksum;
}

function columnMap(columns, tableName) {
  return new Map(
    columns
      .filter((column) => column.tableName === tableName)
      .map((column) => [column.columnName, column])
  );
}

function hasColumns(map, names) {
  return names.every((name) => map.has(name));
}

function normalizeType(value) {
  return String(value ?? '').toLowerCase().replace(/\s+/g, '');
}

export async function inspectFinF01Lifecycle(prisma) {
  const databaseRows = await prisma.$queryRawUnsafe(
    'SELECT DATABASE() AS databaseName'
  );

  const migrationRows = await prisma.$queryRawUnsafe(`
    SELECT migration_name, checksum, started_at, finished_at,
           rolled_back_at, applied_steps_count
    FROM _prisma_migrations
    WHERE migration_name IN (
      '${H02_MIGRATION}',
      '${FIN_F01_MIGRATION}'
    )
    ORDER BY migration_name, started_at
  `);

  const abnormalMigrations = await prisma.$queryRawUnsafe(`
    SELECT migration_name, checksum, started_at, finished_at,
           rolled_back_at, applied_steps_count
    FROM _prisma_migrations
    WHERE finished_at IS NULL
       OR rolled_back_at IS NOT NULL
    ORDER BY started_at
  `);

  const tables = await prisma.$queryRawUnsafe(`
    SELECT TABLE_NAME AS tableName
    FROM information_schema.TABLES
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME IN ('payments', 'payments_fin_f01_write_frozen')
  `);

  const columns = await prisma.$queryRawUnsafe(`
    SELECT TABLE_NAME AS tableName,
           COLUMN_NAME AS columnName,
           COLUMN_TYPE AS columnType,
           IS_NULLABLE AS isNullable,
           COLUMN_DEFAULT AS columnDefault
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME IN ('payments', 'payments_fin_f01_write_frozen')
    ORDER BY TABLE_NAME, ORDINAL_POSITION
  `);

  const h02Rows = migrationRows.filter(
    (row) => row.migration_name === H02_MIGRATION
  );
  const finRows = migrationRows.filter(
    (row) => row.migration_name === FIN_F01_MIGRATION
  );

  const paymentColumns = columnMap(columns, 'payments');
  const tableNames = new Set(tables.map((table) => table.tableName));

  const h02Valid = activeMigration(h02Rows, APPROVED_H02_CHECKSUM);
  const finApplied = activeMigration(finRows, APPROVED_FIN_F01_CHECKSUM);

  const paymentsExists = tableNames.has('payments');
  const frozenTableExists = tableNames.has('payments_fin_f01_write_frozen');
  const legacyColumnsPresent = hasColumns(paymentColumns, LEGACY_PAYMENT_COLUMNS);
  const finColumnsPresent = hasColumns(paymentColumns, FIN_F01_COLUMNS);
  const anyFinColumnPresent = FIN_F01_COLUMNS.some((name) => paymentColumns.has(name));
  const amountType = normalizeType(paymentColumns.get('amount')?.columnType);

  const postNullabilityValid =
    paymentColumns.get('organizationId')?.isNullable === 'NO' &&
    paymentColumns.get('clientOperationId')?.isNullable === 'NO' &&
    paymentColumns.get('version')?.isNullable === 'NO';

  const reasons = [];

  if (!h02Valid) reasons.push('H02_MIGRATION_OR_CHECKSUM_INVALID');
  if (abnormalMigrations.length > 0) reasons.push('ABNORMAL_MIGRATION_LEDGER');
  if (!paymentsExists) reasons.push('PAYMENTS_TABLE_MISSING');
  if (frozenTableExists) reasons.push('FIN_F01_FROZEN_TABLE_PRESENT');
  if (!legacyColumnsPresent) reasons.push('PAYMENTS_BASE_SCHEMA_INCOMPLETE');

  let state = FinF01State.INVALID_OR_PARTIAL;

  const commonValid =
    h02Valid &&
    abnormalMigrations.length === 0 &&
    paymentsExists &&
    !frozenTableExists &&
    legacyColumnsPresent;

  if (commonValid && finRows.length === 0) {
    const exactPreSchema = !anyFinColumnPresent && amountType === 'decimal(10,2)';
    if (exactPreSchema) {
      state = FinF01State.PRE_MIGRATION;
    } else {
      reasons.push('PRE_SCHEMA_DOES_NOT_MATCH_LEGACY_PAYMENT');
    }
  } else if (commonValid && finApplied) {
    const exactPostSchema =
      finColumnsPresent &&
      postNullabilityValid &&
      amountType === 'decimal(14,2)';

    if (exactPostSchema) {
      state = FinF01State.POST_MIGRATION;
    } else {
      reasons.push('POST_SCHEMA_DOES_NOT_MATCH_FIN_F01');
    }
  } else if (finRows.length > 0 && !finApplied) {
    reasons.push('FIN_F01_MIGRATION_LEDGER_INVALID');
  }

  if (state === FinF01State.INVALID_OR_PARTIAL && reasons.length === 0) {
    reasons.push('UNCLASSIFIED_FIN_F01_STATE');
  }

  return {
    database: databaseRows[0]?.databaseName ?? null,
    state,
    reasons,
    h02: h02Rows,
    finF01: finRows,
    h02ChecksumMatch:
      h02Rows.length === 1 && h02Rows[0].checksum === APPROVED_H02_CHECKSUM,
    finF01ChecksumMatch:
      finRows.length === 1 && finRows[0].checksum === APPROVED_FIN_F01_CHECKSUM,
    abnormalMigrations,
    schema: {
      paymentsExists,
      frozenTableExists,
      amountType,
      postNullabilityValid,
      columns: columns.filter((column) => column.tableName === 'payments'),
    },
  };
}

export function jsonReplacer(_, value) {
  return typeof value === 'bigint' ? value.toString() : value;
}
