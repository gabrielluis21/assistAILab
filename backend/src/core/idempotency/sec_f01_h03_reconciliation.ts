import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';

import type {
  Prisma,
  PrismaClient,
} from '@prisma/client';

export const SEC_F01_H03_OLD_MIGRATION =
  '20260826_sec_f01_idempotency_v2';

export const SEC_F01_H03_NEW_MIGRATION =
  '20260826163000_sec_f01_idempotency_v2';

export const SEC_F01_H03_CLEANUP_MIGRATION =
  '20260826163526_';

export const SEC_F01_H03_H02_MIGRATION =
  '20260826164000_sec_f01_h02_lease_ownership';

export const SEC_F01_H03_APPROVED_CHECKSUM =
  '77153c184a35d7e775a98f9d4da2537d7d4b1305552ea5b1f24c1d95678e4a4b';

export const SEC_F01_H03_DISPOSABLE_DB =
  'assistailab_sec_f01_h03';

export type MigrationRow = {
  id: string;
  migration_name: string;
  checksum: string;
  finished_at: Date | null;
  migration_name_before?: string;
  logs: string | null;
  rolled_back_at: Date | null;
  started_at: Date;
  applied_steps_count: number | bigint;
};

export type ColumnRow = {
  columnName: string;
  isNullable: string;
  columnType: string;
  columnDefault: unknown;
  extra: string;
};

export type IndexRow = {
  indexName: string;
  seqInIndex: number | bigint;
  columnName: string;
};

export type H03Snapshot = {
  oldRows: MigrationRow[];
  newRows: MigrationRow[];
  cleanupRows: MigrationRow[];
  h02Rows: MigrationRow[];
  columns: ColumnRow[];
  indexes: IndexRow[];
  localMigrationChecksum: string;
};

export type H03Evaluation =
  | {
      state: 'READY';
      reasons: [];
    }
  | {
      state: 'ALREADY_RECONCILED';
      reasons: [];
    }
  | {
      state: 'BLOCKED';
      reasons: string[];
    };

type DbClient =
  | PrismaClient
  | Prisma.TransactionClient;

function dateMillis(value: Date | null): number | null {
  return value === null ? null : value.getTime();
}

function sameScalar(
  left: string | number | bigint | null,
  right: string | number | bigint | null
): boolean {
  if (typeof left === 'bigint' || typeof right === 'bigint') {
    return String(left) === String(right);
  }

  return left === right;
}

export function assertOnlyMigrationNameChanged(
  before: MigrationRow,
  after: MigrationRow
): void {
  const checks: Array<[string, boolean]> = [
    ['id', before.id === after.id],
    ['checksum', before.checksum === after.checksum],
    ['finished_at', dateMillis(before.finished_at) === dateMillis(after.finished_at)],
    ['logs', before.logs === after.logs],
    ['rolled_back_at', dateMillis(before.rolled_back_at) === dateMillis(after.rolled_back_at)],
    ['started_at', dateMillis(before.started_at) === dateMillis(after.started_at)],
    [
      'applied_steps_count',
      sameScalar(before.applied_steps_count, after.applied_steps_count),
    ],
  ];

  const changedUnexpectedly = checks
    .filter(([, ok]) => !ok)
    .map(([field]) => field);

  if (changedUnexpectedly.length > 0) {
    throw new Error(
      `H03 invariant violation: fields changed besides migration_name: ${changedUnexpectedly.join(', ')}`
    );
  }

  if (after.migration_name !== SEC_F01_H03_NEW_MIGRATION) {
    throw new Error(
      `H03 invariant violation: migration_name is '${after.migration_name}', expected '${SEC_F01_H03_NEW_MIGRATION}'`
    );
  }
}

function migrationIsCompleted(row: MigrationRow): boolean {
  return row.finished_at !== null && row.rolled_back_at === null;
}

function columnMap(columns: ColumnRow[]): Map<string, ColumnRow> {
  return new Map(columns.map((column) => [column.columnName, column]));
}

function hasExactIndex(
  indexes: IndexRow[],
  indexName: string,
  columns: string[]
): boolean {
  const actual = indexes
    .filter((index) => index.indexName === indexName)
    .sort(
      (a, b) =>
        Number(a.seqInIndex) - Number(b.seqInIndex)
    )
    .map((index) => index.columnName);

  return (
    actual.length === columns.length &&
    actual.every(
      (column, position) =>
        column === columns[position]
    )
  );
}

function evaluateSecF01Schema(
  snapshot: H03Snapshot
): string[] {
  const reasons: string[] = [];
  const columns = columnMap(snapshot.columns);

  const requiredColumns = [
    'organizationId',
    'command',
    'status',
    'processingExpiresAt',
    'completedAt',
    'updatedAt',
    'responseStatus',
    'responseBody',
  ];

  for (const name of requiredColumns) {
    if (!columns.has(name)) {
      reasons.push(
        `SEC-F01 schema mismatch: missing operation_idempotency.${name}`
      );
    }
  }

  const status = columns.get('status');
  if (status) {
    const type = status.columnType.toLowerCase();

    if (
      !type.includes('enum') ||
      !type.includes('processing') ||
      !type.includes('completed')
    ) {
      reasons.push(
        `SEC-F01 schema mismatch: status column type is '${status.columnType}'`
      );
    }

    if (status.isNullable.toUpperCase() !== 'NO') {
      reasons.push(
        'SEC-F01 schema mismatch: status must be NOT NULL'
      );
    }
  }

  const responseStatus = columns.get('responseStatus');
  if (
    responseStatus &&
    responseStatus.isNullable.toUpperCase() !== 'YES'
  ) {
    reasons.push(
      'SEC-F01 schema mismatch: responseStatus must be nullable'
    );
  }

  const responseBody = columns.get('responseBody');
  if (
    responseBody &&
    responseBody.isNullable.toUpperCase() !== 'YES'
  ) {
    reasons.push(
      'SEC-F01 schema mismatch: responseBody must be nullable'
    );
  }

  const updatedAt = columns.get('updatedAt');
  if (
    updatedAt &&
    updatedAt.columnDefault === null
  ) {
    reasons.push(
      'SEC-F01 pre-cleanup schema mismatch: updatedAt default is already absent'
    );
  }

  if (columns.has('leaseToken')) {
    reasons.push(
      'SEC-F01-H02 schema mismatch: leaseToken already exists before repair'
    );
  }

  if (
    !hasExactIndex(
      snapshot.indexes,
      'operation_idempotency_status_processingExpiresAt_idx',
      ['status', 'processingExpiresAt']
    )
  ) {
    reasons.push(
      'SEC-F01 schema mismatch: status/processingExpiresAt index missing or different'
    );
  }

  if (
    !hasExactIndex(
      snapshot.indexes,
      'operation_idempotency_organizationId_idx',
      ['organizationId']
    )
  ) {
    reasons.push(
      'SEC-F01 schema mismatch: organizationId index missing or different'
    );
  }

  if (
    !hasExactIndex(
      snapshot.indexes,
      'operation_idempotency_command_idx',
      ['command']
    )
  ) {
    reasons.push(
      'SEC-F01 schema mismatch: command index missing or different'
    );
  }

  return reasons;
}

export function evaluateH03Snapshot(
  snapshot: H03Snapshot
): H03Evaluation {
  const reasons: string[] = [];

  if (
    snapshot.localMigrationChecksum !==
    SEC_F01_H03_APPROVED_CHECKSUM
  ) {
    reasons.push(
      `Local SEC-F01 migration checksum mismatch: got ${snapshot.localMigrationChecksum}`
    );
  }

  const oldCount = snapshot.oldRows.length;
  const newCount = snapshot.newRows.length;

  if (oldCount === 0 && newCount === 1) {
    const current = snapshot.newRows[0];

    if (!migrationIsCompleted(current)) {
      reasons.push(
        'NEW migration exists but is not completed cleanly'
      );
    }

    if (
      current.checksum !==
      SEC_F01_H03_APPROVED_CHECKSUM
    ) {
      reasons.push(
        `NEW migration checksum mismatch: got ${current.checksum}`
      );
    }

    if (reasons.length === 0) {
      return {
        state: 'ALREADY_RECONCILED',
        reasons: [],
      };
    }

    return {
      state: 'BLOCKED',
      reasons,
    };
  }

  if (oldCount !== 1) {
    reasons.push(
      `OLD migration must exist exactly once; found ${oldCount}`
    );
  }

  if (newCount !== 0) {
    reasons.push(
      `NEW migration must be absent before reconciliation; found ${newCount}`
    );
  }

  if (snapshot.cleanupRows.length !== 0) {
    reasons.push(
      `Cleanup migration must be absent before reconciliation; found ${snapshot.cleanupRows.length}`
    );
  }

  if (snapshot.h02Rows.length !== 0) {
    reasons.push(
      `H02 migration must be absent before reconciliation; found ${snapshot.h02Rows.length}`
    );
  }

  if (oldCount === 1) {
    const old = snapshot.oldRows[0];

    if (old.finished_at === null) {
      reasons.push(
        'OLD migration is not COMPLETED: finished_at is NULL'
      );
    }

    if (old.rolled_back_at !== null) {
      reasons.push(
        'OLD migration is rolled back'
      );
    }

    if (
      old.checksum !==
      SEC_F01_H03_APPROVED_CHECKSUM
    ) {
      reasons.push(
        `OLD migration checksum mismatch: got ${old.checksum}`
      );
    }

    if (
      Number(old.applied_steps_count) < 1
    ) {
      reasons.push(
        'OLD migration has no applied steps'
      );
    }
  }

  reasons.push(
    ...evaluateSecF01Schema(snapshot)
  );

  if (reasons.length > 0) {
    return {
      state: 'BLOCKED',
      reasons,
    };
  }

  return {
    state: 'READY',
    reasons: [],
  };
}

export function computeLocalSecF01Checksum(
  backendRoot = process.cwd()
): string {
  const migrationPath = path.resolve(
    backendRoot,
    'prisma',
    'migrations',
    SEC_F01_H03_NEW_MIGRATION,
    'migration.sql'
  );

  const bytes = readFileSync(migrationPath);

  return createHash('sha256')
    .update(bytes)
    .digest('hex');
}

export async function assertDisposableDatabase(
  client: DbClient,
  databaseUrl = process.env.DATABASE_URL
): Promise<void> {
  if (!databaseUrl) {
    throw new Error(
      'DATABASE_URL is required'
    );
  }

  let url: URL;

  try {
    url = new URL(databaseUrl);
  } catch {
    throw new Error(
      'DATABASE_URL is not a valid URL'
    );
  }

  const urlDbName = url.pathname
    .replace(/^\/+/, '')
    .replace(/\/+$/, '');

  if (
    urlDbName !==
    SEC_F01_H03_DISPOSABLE_DB
  ) {
    throw new Error(
      `SEC-F01-H03 safety stop: only disposable database '${SEC_F01_H03_DISPOSABLE_DB}' is allowed; URL targets '${urlDbName}'`
    );
  }

  const rows = (await client.$queryRawUnsafe(
    'SELECT DATABASE() AS databaseName'
  )) as Array<{
    databaseName: string | null;
  }>;

  if (
    rows.length !== 1 ||
    rows[0].databaseName !==
      SEC_F01_H03_DISPOSABLE_DB
  ) {
    throw new Error(
      `SEC-F01-H03 safety stop: connected database is '${rows[0]?.databaseName ?? 'unknown'}'`
    );
  }
}

export async function readH03Snapshot(
  client: DbClient,
  options: {
    lockMigrationRows?: boolean;
    backendRoot?: string;
  } = {}
): Promise<H03Snapshot> {
  const lock = options.lockMigrationRows
    ? ' FOR UPDATE'
    : '';

  const migrations = (await client.$queryRawUnsafe(
    `
      SELECT
        id,
        migration_name,
        checksum,
        finished_at,
        logs,
        rolled_back_at,
        started_at,
        applied_steps_count
      FROM _prisma_migrations
      WHERE migration_name IN (
        '${SEC_F01_H03_OLD_MIGRATION}',
        '${SEC_F01_H03_NEW_MIGRATION}',
        '${SEC_F01_H03_CLEANUP_MIGRATION}',
        '${SEC_F01_H03_H02_MIGRATION}'
      )
      ORDER BY started_at
      ${lock}
    `
  )) as MigrationRow[];

  const columns = (await client.$queryRawUnsafe(
    `
      SELECT
        COLUMN_NAME AS columnName,
        IS_NULLABLE AS isNullable,
        COLUMN_TYPE AS columnType,
        COLUMN_DEFAULT AS columnDefault,
        EXTRA AS extra
      FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'operation_idempotency'
      ORDER BY ORDINAL_POSITION
    `
  )) as ColumnRow[];

  const indexes = (await client.$queryRawUnsafe(
    `
      SELECT
        INDEX_NAME AS indexName,
        SEQ_IN_INDEX AS seqInIndex,
        COLUMN_NAME AS columnName
      FROM information_schema.STATISTICS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = 'operation_idempotency'
      ORDER BY INDEX_NAME, SEQ_IN_INDEX
    `
  )) as IndexRow[];

  return {
    oldRows: migrations.filter(
      (row) =>
        row.migration_name ===
        SEC_F01_H03_OLD_MIGRATION
    ),
    newRows: migrations.filter(
      (row) =>
        row.migration_name ===
        SEC_F01_H03_NEW_MIGRATION
    ),
    cleanupRows: migrations.filter(
      (row) =>
        row.migration_name ===
        SEC_F01_H03_CLEANUP_MIGRATION
    ),
    h02Rows: migrations.filter(
      (row) =>
        row.migration_name ===
        SEC_F01_H03_H02_MIGRATION
    ),
    columns,
    indexes,
    localMigrationChecksum:
      computeLocalSecF01Checksum(
        options.backendRoot
      ),
  };
}

export async function applyH03Reconciliation(
  prisma: PrismaClient,
  backendRoot = process.cwd()
): Promise<
  'APPLIED' | 'ALREADY_RECONCILED'
> {
  await assertDisposableDatabase(prisma);

  return prisma.$transaction(
    async (tx) => {
      await assertDisposableDatabase(tx);

      const snapshot =
        await readH03Snapshot(tx, {
          lockMigrationRows: true,
          backendRoot,
        });

      const evaluation =
        evaluateH03Snapshot(snapshot);

      if (
        evaluation.state ===
        'ALREADY_RECONCILED'
      ) {
        return 'ALREADY_RECONCILED';
      }

      if (
        evaluation.state !== 'READY'
      ) {
        throw new Error(
          `SEC-F01-H03 reconciliation blocked:\n- ${evaluation.reasons.join('\n- ')}`
        );
      }

      const before = snapshot.oldRows[0];

      const affected =
        await tx.$executeRawUnsafe(
          `
            UPDATE _prisma_migrations
            SET migration_name = ?
            WHERE id = ?
              AND migration_name = ?
              AND checksum = ?
              AND finished_at IS NOT NULL
              AND rolled_back_at IS NULL
          `,
          SEC_F01_H03_NEW_MIGRATION,
          before.id,
          SEC_F01_H03_OLD_MIGRATION,
          SEC_F01_H03_APPROVED_CHECKSUM
        );

      if (affected !== 1) {
        throw new Error(
          `SEC-F01-H03 affected-row assertion failed: expected 1, got ${affected}`
        );
      }

      const afterRows =
        (await tx.$queryRawUnsafe(
          `
            SELECT
              id,
              migration_name,
              checksum,
              finished_at,
              logs,
              rolled_back_at,
              started_at,
              applied_steps_count
            FROM _prisma_migrations
            WHERE id = ?
            FOR UPDATE
          `,
          before.id
        )) as MigrationRow[];

      if (afterRows.length !== 1) {
        throw new Error(
          `SEC-F01-H03 post-update assertion failed: expected 1 row, got ${afterRows.length}`
        );
      }

      assertOnlyMigrationNameChanged(
        before,
        afterRows[0]
      );

      return 'APPLIED';
    },
    {
      isolationLevel: 'Serializable',
    }
  );
}
