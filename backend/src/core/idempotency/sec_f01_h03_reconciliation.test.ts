import {
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  SEC_F01_H03_APPROVED_CHECKSUM,
  SEC_F01_H03_NEW_MIGRATION,
  SEC_F01_H03_OLD_MIGRATION,
  assertOnlyMigrationNameChanged,
  evaluateH03Snapshot,
  type ColumnRow,
  type H03Snapshot,
  type IndexRow,
  type MigrationRow,
} from './sec_f01_h03_reconciliation.js';

function migration(
  name: string,
  overrides: Partial<MigrationRow> = {}
): MigrationRow {
  return {
    id: 'migration-id',
    migration_name: name,
    checksum:
      SEC_F01_H03_APPROVED_CHECKSUM,
    finished_at: new Date(
      '2026-08-26T18:37:42.748Z'
    ),
    logs: null,
    rolled_back_at: null,
    started_at: new Date(
      '2026-08-26T18:37:42.554Z'
    ),
    applied_steps_count: 1,
    ...overrides,
  };
}

function columns(): ColumnRow[] {
  return [
    {
      columnName: 'organizationId',
      isNullable: 'YES',
      columnType: 'varchar(191)',
      columnDefault: null,
      extra: '',
    },
    {
      columnName: 'command',
      isNullable: 'YES',
      columnType: 'varchar(191)',
      columnDefault: null,
      extra: '',
    },
    {
      columnName: 'status',
      isNullable: 'NO',
      columnType:
        "enum('PROCESSING','COMPLETED')",
      columnDefault: 'COMPLETED',
      extra: '',
    },
    {
      columnName: 'processingExpiresAt',
      isNullable: 'YES',
      columnType: 'datetime(3)',
      columnDefault: null,
      extra: '',
    },
    {
      columnName: 'completedAt',
      isNullable: 'YES',
      columnType: 'datetime(3)',
      columnDefault: null,
      extra: '',
    },
    {
      columnName: 'updatedAt',
      isNullable: 'NO',
      columnType: 'datetime(3)',
      columnDefault:
        'CURRENT_TIMESTAMP(3)',
      extra: '',
    },
    {
      columnName: 'responseStatus',
      isNullable: 'YES',
      columnType: 'int',
      columnDefault: null,
      extra: '',
    },
    {
      columnName: 'responseBody',
      isNullable: 'YES',
      columnType: 'json',
      columnDefault: null,
      extra: '',
    },
  ];
}

function indexes(): IndexRow[] {
  return [
    {
      indexName:
        'operation_idempotency_status_processingExpiresAt_idx',
      seqInIndex: 1,
      columnName: 'status',
    },
    {
      indexName:
        'operation_idempotency_status_processingExpiresAt_idx',
      seqInIndex: 2,
      columnName: 'processingExpiresAt',
    },
    {
      indexName:
        'operation_idempotency_organizationId_idx',
      seqInIndex: 1,
      columnName: 'organizationId',
    },
    {
      indexName:
        'operation_idempotency_command_idx',
      seqInIndex: 1,
      columnName: 'command',
    },
  ];
}

function readySnapshot(): H03Snapshot {
  return {
    oldRows: [
      migration(
        SEC_F01_H03_OLD_MIGRATION
      ),
    ],
    newRows: [],
    cleanupRows: [],
    h02Rows: [],
    columns: columns(),
    indexes: indexes(),
    localMigrationChecksum:
      SEC_F01_H03_APPROVED_CHECKSUM,
  };
}

describe(
  'SEC-F01-H03 migration identity reconciliation',
  () => {
    test(
      'accepts the exact approved historical state',
      () => {
        assert.deepEqual(
          evaluateH03Snapshot(
            readySnapshot()
          ),
          {
            state: 'READY',
            reasons: [],
          }
        );
      }
    );

    test(
      'blocks when OLD is missing',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows = [];

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks duplicate OLD rows',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows.push(
          migration(
            SEC_F01_H03_OLD_MIGRATION,
            { id: 'duplicate' }
          )
        );

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks unfinished OLD migration',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows[0].finished_at =
          null;

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks rolled-back OLD migration',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows[0].rolled_back_at =
          new Date();

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks OLD checksum mismatch',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows[0].checksum =
          'bad-checksum';

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks local migration checksum mismatch',
      () => {
        const snapshot = readySnapshot();
        snapshot.localMigrationChecksum =
          'bad-local-checksum';

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks when NEW already coexists with OLD',
      () => {
        const snapshot = readySnapshot();
        snapshot.newRows = [
          migration(
            SEC_F01_H03_NEW_MIGRATION,
            { id: 'new-id' }
          ),
        ];

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks when cleanup is already recorded',
      () => {
        const snapshot = readySnapshot();
        snapshot.cleanupRows = [
          migration(
            '20260826163526_',
            { id: 'cleanup-id' }
          ),
        ];

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks when H02 is already recorded',
      () => {
        const snapshot = readySnapshot();
        snapshot.h02Rows = [
          migration(
            '20260826164000_sec_f01_h02_lease_ownership',
            { id: 'h02-id' }
          ),
        ];

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks when SEC-F01 schema column is missing',
      () => {
        const snapshot = readySnapshot();
        snapshot.columns =
          snapshot.columns.filter(
            (column) =>
              column.columnName !==
              'organizationId'
          );

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks if cleanup appears already applied in schema',
      () => {
        const snapshot = readySnapshot();
        const updatedAt =
          snapshot.columns.find(
            (column) =>
              column.columnName ===
              'updatedAt'
          );

        assert.ok(updatedAt);
        updatedAt.columnDefault = null;

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks if H02 leaseToken already exists',
      () => {
        const snapshot = readySnapshot();
        snapshot.columns.push({
          columnName: 'leaseToken',
          isNullable: 'YES',
          columnType: 'varchar(191)',
          columnDefault: null,
          extra: '',
        });

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'blocks when required SEC-F01 index is missing',
      () => {
        const snapshot = readySnapshot();
        snapshot.indexes =
          snapshot.indexes.filter(
            (index) =>
              index.indexName !==
              'operation_idempotency_command_idx'
          );

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'recognizes an already reconciled migration as idempotent state',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows = [];
        snapshot.newRows = [
          migration(
            SEC_F01_H03_NEW_MIGRATION
          ),
        ];

        assert.deepEqual(
          evaluateH03Snapshot(snapshot),
          {
            state:
              'ALREADY_RECONCILED',
            reasons: [],
          }
        );
      }
    );

    test(
      'blocks an already-named NEW row when it is failed',
      () => {
        const snapshot = readySnapshot();
        snapshot.oldRows = [];
        snapshot.newRows = [
          migration(
            SEC_F01_H03_NEW_MIGRATION,
            {
              finished_at: null,
            }
          ),
        ];

        assert.equal(
          evaluateH03Snapshot(snapshot)
            .state,
          'BLOCKED'
        );
      }
    );

    test(
      'post-update invariant allows only migration_name to change',
      () => {
        const before = migration(
          SEC_F01_H03_OLD_MIGRATION
        );
        const after = {
          ...before,
          migration_name:
            SEC_F01_H03_NEW_MIGRATION,
        };

        assert.doesNotThrow(() =>
          assertOnlyMigrationNameChanged(
            before,
            after
          )
        );
      }
    );

    test(
      'post-update invariant rejects any other field mutation',
      () => {
        const before = migration(
          SEC_F01_H03_OLD_MIGRATION
        );
        const after = {
          ...before,
          migration_name:
            SEC_F01_H03_NEW_MIGRATION,
          checksum: 'mutated',
        };

        assert.throws(() =>
          assertOnlyMigrationNameChanged(
            before,
            after
          )
        );
      }
    );
  }
);
