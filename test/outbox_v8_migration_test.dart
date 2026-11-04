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
        expectedRemote: 'CONFIRMED'
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
        expectedRemote: 'UNSENT'
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

    final snapshot = migrated.map(Map<String, Object?>.from).toList();
    await SqliteDatabase.migrateV7ToV8(db);
    expect(await db.query('outbox', orderBy: 'operation_id'), snapshot);
  });
}
