import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('v7 to v8 classifies legacy states conservatively and is idempotent',
      () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''CREATE TABLE outbox (
      operation_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL, operation_type TEXT NOT NULL,
      payload TEXT NOT NULL, created_at TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0, last_attempt_at TEXT,
      next_retry_at TEXT, last_error TEXT, status TEXT NOT NULL)''');

    final cases = <({
      String id,
      String type,
      String op,
      String status,
      int attempts,
      String? lastAttempt,
      String? error,
      String expectedStatus,
      String expectedRemote
    })>[
      (
        id: 'pending',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'PENDING',
        attempts: 0,
        lastAttempt: null,
        error: null,
        expectedStatus: 'PENDING',
        expectedRemote: 'UNSENT'
      ),
      (
        id: 'pending-attempted',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'PENDING',
        attempts: 1,
        lastAttempt: '2026-01-01',
        error: null,
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'processing',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'PROCESSING',
        attempts: 1,
        lastAttempt: '2026-01-01',
        error: null,
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'failed-unsent',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'FAILED',
        attempts: 0,
        lastAttempt: null,
        error: null,
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'failed-attempted',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'FAILED',
        attempts: 2,
        lastAttempt: '2026-01-01',
        error: 'timeout',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'synced',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'SYNCED',
        attempts: 1,
        lastAttempt: '2026-01-01',
        error: null,
        expectedStatus: 'SYNCED',
        expectedRemote: 'CONFIRMED'
      ),
      (
        id: 'conflict',
        type: 'SERVICE_ORDER',
        op: 'UPDATE',
        status: 'CONFLICT',
        attempts: 1,
        lastAttempt: '2026-01-01',
        error: 'domain conflict',
        expectedStatus: 'CONFLICT',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'p08',
        type: 'PRE_ACQUISITION',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: null,
        error: null,
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'p08-local-only-marker',
        type: 'PRE_ACQUISITION',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: null,
        error: 'PRE_ACQUISITION_LOCAL_ONLY',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'UNSENT'
      ),
      (
        id: 'p08-attempt-count',
        type: 'PRE_ACQUISITION',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 1,
        lastAttempt: null,
        error: 'PRE_ACQUISITION_LOCAL_ONLY',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'p08-last-attempt',
        type: 'PRE_ACQUISITION',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: '2026-01-01',
        error: 'PRE_ACQUISITION_LOCAL_ONLY',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'part-intercept',
        type: 'PART',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: null,
        error: 'PART_TENANCY_REQUIRED',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'UNSENT'
      ),
      (
        id: 'part-intercept-attempted',
        type: 'PART',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 1,
        lastAttempt: null,
        error: 'PART_TENANCY_REQUIRED',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'part-marker-last-attempt',
        type: 'PART',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: '2026-01-01',
        error: 'PART_TENANCY_REQUIRED',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'payment-intercept',
        type: 'PAYMENT',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: null,
        error: 'FINANCE_COMMAND_REQUIRED',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'UNSENT'
      ),
      (
        id: 'payment-intercept-attempted',
        type: 'PAYMENT',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 1,
        lastAttempt: null,
        error: 'FINANCE_COMMAND_REQUIRED',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'fe02b',
        type: 'PAYMENT',
        op: 'CREATE',
        status: 'REQUIRES_ATTENTION',
        attempts: 0,
        lastAttempt: null,
        error: 'FE02B_LEGACY_MONEY_RECONCILIATION_REQUIRED',
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
      (
        id: 'unknown',
        type: 'CUSTOMER',
        op: 'CREATE',
        status: 'RETIRED_UNKNOWN',
        attempts: 0,
        lastAttempt: null,
        error: null,
        expectedStatus: 'REQUIRES_ATTENTION',
        expectedRemote: 'AMBIGUOUS'
      ),
    ];

    for (final item in cases) {
      await db.insert('outbox', {
        'operation_id': item.id,
        'entity_type': item.type,
        'entity_id': item.id,
        'operation_type': item.op,
        'payload': '{}',
        'created_at': '2026-01-01',
        'attempt_count': item.attempts,
        'last_attempt_at': item.lastAttempt,
        'last_error': item.error,
        'status': item.status,
      });
    }

    await SqliteDatabase.migrateV7ToV8(db);
    final migrated = await db.query('outbox', orderBy: 'operation_id');
    for (var i = 0; i < cases.length; i++) {
      final item = cases[i];
      final row = migrated.singleWhere((row) => row['operation_id'] == item.id);
      expect(row['status'], item.expectedStatus, reason: item.id);
      expect(row['remote_disposition'], item.expectedRemote, reason: item.id);
      expect(row['payload'], '{}', reason: 'payload preserved: ${item.id}');
    }

    final alteredAfterMigration = await db.query('outbox');
    expect(alteredAfterMigration, hasLength(cases.length));

    final snapshot = migrated.map(Map<String, Object?>.from).toList();
    await SqliteDatabase.migrateV7ToV8(db);
    expect(await db.query('outbox', orderBy: 'operation_id'), snapshot);
  });

  test('v8 to v9 classifies historical outcomes from evidence and is idempotent', () async {
    final db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    addTearDown(db.close);
    await db.execute('''CREATE TABLE outbox (
      operation_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL, operation_type TEXT NOT NULL,
      payload TEXT NOT NULL, created_at TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0, last_attempt_at TEXT,
      next_retry_at TEXT, last_error TEXT, status TEXT NOT NULL,
      remote_disposition TEXT NOT NULL)''');
    final cases = <({
      String id,
      String type,
      String status,
      String disposition,
      int attempts,
      String? lastAttempt,
      String? lastError,
      String expectedStatus,
      String expectedDisposition,
      String rationale,
    })>[
      (id: 'synced-confirmed', type: 'CUSTOMER', status: 'SYNCED', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: null, expectedStatus: 'SYNCED', expectedDisposition: 'CONFIRMED', rationale: 'Explicit server acknowledgement for this operation id.'),
      (id: 'conflict-ambiguous', type: 'CUSTOMER', status: 'CONFLICT', disposition: 'AMBIGUOUS', attempts: 1, lastAttempt: '2026-01-01', lastError: 'IDEMPOTENCY_OPERATION_IN_PROGRESS', expectedStatus: 'CONFLICT', expectedDisposition: 'AMBIGUOUS', rationale: 'Conflict does not prove whether the server applied the operation.'),
      (id: 'conflict-falsely-confirmed', type: 'CUSTOMER', status: 'CONFLICT', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'IDEMPOTENCY_KEY_REUSE', expectedStatus: 'CONFLICT', expectedDisposition: 'AMBIGUOUS', rationale: 'v8 promoted conflicts to confirmed without proof.'),
      (id: 'superseded-confirmed-no-attempt', type: 'CUSTOMER', status: 'SUPERSEDED', disposition: 'CONFIRMED', attempts: 0, lastAttempt: null, lastError: 'SYNC_ENTITY_ALREADY_EXISTS', expectedStatus: 'SUPERSEDED', expectedDisposition: 'AMBIGUOUS', rationale: 'Error code without attempt evidence cannot establish the source state.'),
      (id: 'superseded-confirmed-definitive', type: 'CUSTOMER', status: 'SUPERSEDED', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'SYNC_ENTITY_ALREADY_EXISTS', expectedStatus: 'SUPERSEDED', expectedDisposition: 'CONFIRMED', rationale: 'Attempt evidence plus a known per-entry FAILED code proves rejection.'),
      (id: 'superseded-confirmed-unknown', type: 'CUSTOMER', status: 'SUPERSEDED', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'unknown server result', expectedStatus: 'SUPERSEDED', expectedDisposition: 'AMBIGUOUS', rationale: 'Unknown code cannot distinguish failure from an unrecognized response.'),
      (id: 'superseded-unsent-no-attempt', type: 'CUSTOMER', status: 'SUPERSEDED', disposition: 'UNSENT', attempts: 0, lastAttempt: null, lastError: null, expectedStatus: 'SUPERSEDED', expectedDisposition: 'UNSENT', rationale: 'No attempt evidence supports a local-only supersede.'),
      (id: 'superseded-unsent-with-attempt', type: 'CUSTOMER', status: 'SUPERSEDED', disposition: 'UNSENT', attempts: 1, lastAttempt: '2026-01-01', lastError: 'HTTP 429: rate limited', expectedStatus: 'SUPERSEDED', expectedDisposition: 'AMBIGUOUS', rationale: 'v8 could downgrade a transmitted PART/PAYMENT operation to UNSENT.'),
      (id: 'discarded-confirmed-no-attempt', type: 'CUSTOMER', status: 'DISCARDED', disposition: 'CONFIRMED', attempts: 0, lastAttempt: null, lastError: 'SYNC_ENTITY_ALREADY_EXISTS', expectedStatus: 'DISCARDED', expectedDisposition: 'AMBIGUOUS', rationale: 'Discard status alone is not evidence of remote rejection.'),
      (id: 'discarded-confirmed-definitive', type: 'CUSTOMER', status: 'DISCARDED', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'SYNC_ENTITY_ALREADY_EXISTS', expectedStatus: 'DISCARDED', expectedDisposition: 'CONFIRMED', rationale: 'Known individual rejection and transmission evidence are preserved.'),
      (id: 'discarded-ambiguous', type: 'CUSTOMER', status: 'DISCARDED', disposition: 'AMBIGUOUS', attempts: 1, lastAttempt: '2026-01-01', lastError: 'HTTP 500: internal error', expectedStatus: 'DISCARDED', expectedDisposition: 'AMBIGUOUS', rationale: 'Ambiguous terminal history stays ambiguous.'),
      (id: 'failed-transient-confirmed', type: 'CUSTOMER', status: 'FAILED_TRANSIENT', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'HTTP 429: rate limited', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'Batch 429 cannot prove per-operation non-application.'),
      (id: 'failed-fatal-definitive', type: 'CUSTOMER', status: 'FAILED_FATAL', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'SYNC_ENTITY_ALREADY_EXISTS', expectedStatus: 'FAILED_FATAL', expectedDisposition: 'CONFIRMED', rationale: 'Backend emits this per-entry rejection before mutation or after rollback.'),
      (id: 'failed-fatal-unknown', type: 'CUSTOMER', status: 'FAILED_FATAL', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'SYNC_RESULT_UNKNOWN', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'Unknown status/error may have represented an applied operation.'),
      (id: 'failed-fatal-incomplete-evidence', type: 'CUSTOMER', status: 'FAILED_FATAL', disposition: 'CONFIRMED', attempts: 1, lastAttempt: null, lastError: 'SYNC_ENTITY_ALREADY_EXISTS', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'Partial attempt record does not prove the response belongs to this send.'),
      (id: 'clean-pending', type: 'CUSTOMER', status: 'PENDING', disposition: 'UNSENT', attempts: 0, lastAttempt: null, lastError: null, expectedStatus: 'PENDING', expectedDisposition: 'UNSENT', rationale: 'No attempt evidence; safe for first send.'),
      (id: 'attempted-pending', type: 'CUSTOMER', status: 'PENDING', disposition: 'UNSENT', attempts: 1, lastAttempt: null, lastError: null, expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'Attempt count prevents automatic replay when timestamp is missing.'),
      (id: 'part-presend', type: 'PART', status: 'REQUIRES_ATTENTION', disposition: 'UNSENT', attempts: 0, lastAttempt: null, lastError: 'PART_TENANCY_REQUIRED', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'UNSENT', rationale: 'Exact v8 interception marker and no attempt prove pre-send interception.'),
      (id: 'payment-after-attempt', type: 'PAYMENT', status: 'REQUIRES_ATTENTION', disposition: 'UNSENT', attempts: 1, lastAttempt: '2026-01-01', lastError: 'FINANCE_COMMAND_REQUIRED', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'v8 could assign the marker after a previous transmitted attempt.'),
      (id: 'p08-legacy', type: 'PRE_ACQUISITION', status: 'REQUIRES_ATTENTION', disposition: 'UNSENT', attempts: 0, lastAttempt: null, lastError: 'PRE_ACQUISITION_LOCAL_ONLY', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'v8 had no proven pre-send P08 interception path.'),
      (id: 'unknown-status', type: 'CUSTOMER', status: 'FUTURE_STATUS', disposition: 'CONFIRMED', attempts: 1, lastAttempt: '2026-01-01', lastError: 'FUTURE_ERROR', expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'Unknown state is quarantined without inventing history.'),
      (id: 'unknown-disposition', type: 'CUSTOMER', status: 'PENDING', disposition: 'FUTURE_DISPOSITION', attempts: 0, lastAttempt: null, lastError: null, expectedStatus: 'REQUIRES_ATTENTION', expectedDisposition: 'AMBIGUOUS', rationale: 'Unknown disposition does not authorize automatic push.'),
    ];
    for (final item in cases) {
      await db.insert('outbox', {
        'operation_id': item.id,
        'entity_type': item.type,
        'entity_id': item.id,
        'operation_type': 'CREATE',
        'payload': '{"preserved":true}',
        'created_at': '2026-01-01',
        'attempt_count': item.attempts,
        'last_attempt_at': item.lastAttempt,
        'last_error': item.lastError,
        'status': item.status,
        'remote_disposition': item.disposition,
      });
    }

    await SqliteDatabase.migrateV8ToV9(db);
    final first = await db.query('outbox', orderBy: 'operation_id');
    for (final item in cases) {
      final row = first.singleWhere((row) => row['operation_id'] == item.id);
      expect(row['status'], item.expectedStatus, reason: item.rationale);
      expect(row['remote_disposition'], item.expectedDisposition,
          reason: item.rationale);
      expect(row['payload'], '{"preserved":true}', reason: item.id);
      expect(row['attempt_count'], item.attempts, reason: item.id);
      expect(row['last_attempt_at'], item.lastAttempt, reason: item.id);
      expect(row['last_error'], item.lastError, reason: item.id);
      expect(row['entity_id'], item.id, reason: item.id);
      expect(row['operation_id'], item.id, reason: item.id);
    }
    await SqliteDatabase.migrateV8ToV9(db);
    expect(await db.query('outbox', orderBy: 'operation_id'), first);
  });
}
