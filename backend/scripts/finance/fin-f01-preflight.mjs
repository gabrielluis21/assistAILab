import {
  PrismaClient,
} from '@prisma/client';

const prisma =
  new PrismaClient();

const APPROVED_H02_CHECKSUM =
  '8cb94477990bc640d3f416349372b644e7420c8fb835b6871e296b9399e2debf';

try {
  const db =
    await prisma.$queryRawUnsafe(
      'SELECT DATABASE() AS databaseName'
    );

  const h02 =
    await prisma.$queryRawUnsafe(`
      SELECT
        migration_name,
        checksum,
        finished_at,
        rolled_back_at
      FROM _prisma_migrations
      WHERE migration_name =
        '20260826164000_sec_f01_h02_lease_ownership'
    `);

  const failedMigrations =
    await prisma.$queryRawUnsafe(`
      SELECT
        migration_name,
        finished_at,
        rolled_back_at
      FROM _prisma_migrations
      WHERE finished_at IS NULL
        AND rolled_back_at IS NULL
    `);

  const integrity =
    await prisma.$queryRawUnsafe(`
      SELECT
        COUNT(*) AS payment_count,

        SUM(
          so.id IS NULL
        ) AS orphan_service_order_count,

        SUM(
          so.id IS NOT NULL
          AND p.customerId <> so.customerId
        ) AS customer_authority_mismatch_count,

        SUM(
          p.status = 'REFUNDED'
        ) AS legacy_refunded_count,

        SUM(
          p.createdByUserId IS NULL
          AND p.clientOperationId <>
            CONCAT('legacy:', p.id)
        ) AS legacy_operation_id_mismatch_count,

        SUM(
          p.createdByUserId IS NULL
          AND p.version <> 1
        ) AS legacy_version_mismatch_count,

        SUM(
          p.createdByUserId IS NULL
        ) AS ratified_legacy_history_count

      FROM payments p
      LEFT JOIN service_orders so
        ON so.id = p.serviceOrderId
    `);

  const h02Rows =
    h02;

  const failedRows =
    failedMigrations;

  const integrityRow =
    integrity[0];

  const h02ChecksumMatch =
    h02Rows.length === 1 &&
    h02Rows[0].checksum ===
      APPROVED_H02_CHECKSUM;

  const pass =
    h02Rows.length === 1 &&
    h02Rows[0].finished_at !==
      null &&
    h02Rows[0].rolled_back_at ===
      null &&
    h02ChecksumMatch &&
    failedRows.length === 0 &&
    Number(
      integrityRow
        .orphan_service_order_count ??
      0
    ) === 0 &&
    Number(
      integrityRow
        .customer_authority_mismatch_count ??
      0
    ) === 0 &&
    Number(
      integrityRow
        .legacy_operation_id_mismatch_count ??
      0
    ) === 0 &&
    Number(
      integrityRow
        .legacy_version_mismatch_count ??
      0
    ) === 0;

  console.log(
    JSON.stringify(
      {
        gate:
          'FIN-F01-PREFLIGHT',

        database:
          db[0]
            ?.databaseName ??
          null,

        approvedH02Checksum:
          APPROVED_H02_CHECKSUM,

        h02:
          h02Rows,

        h02ChecksumMatch,

        failedMigrations:
          failedRows,

        integrity:
          integrityRow,

        result:
          pass
            ? 'PASS'
            : 'FAIL',

        note:
          'Fail-closed FIN-F01 repository preflight: exact H02 checksum, zero orphan/customer-authority mismatch, and ratified historical legacy:<paymentId>/version=1 invariants are mandatory.',
      },
      (
        _,
        value
      ) =>
        typeof value ===
        'bigint'
          ? value.toString()
          : value,
      2
    )
  );

  if (!pass) {
    process.exitCode =
      2;
  }
} finally {
  await prisma
    .$disconnect();
}
