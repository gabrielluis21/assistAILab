import 'package:assistailab/core/commands/command_intent.dart';
import 'package:assistailab/core/commands/command_executor.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('M1 UNKNOWN survives v6 to v7 and retry retains operationId', () async {
    final db = await _openV6();
    addTearDown(db.close);
    await _insertLegacy(db, lifecycle: 'UNKNOWN');

    await SqliteDatabase.migrateV6ToV7(db);

    final migrated = CommandIntent.fromMap(
      (await db.query('command_intents')).single,
    );
    expect(migrated.operationId, 'operation-a');
    expect(migrated.commandType, 'PAYMENT_CREATE');
    expect(migrated.targetId, 'order-1');
    expect(migrated.canonicalPayload, _payload);
    expect(migrated.lifecycle, CommandIntentLifecycle.unknown);
    expect(migrated.createdAt, _createdAt);
    expect(migrated.updatedAt, _updatedAt);
    expect(await _tableExists(db, 'payment_command_intents'), isFalse);

    var factoryCalls = 0;
    final dispatched = <String>[];
    await CommandExecutor(
      intentRepository: CommandIntentLocalDataSource(),
      database: db,
      isBindingCurrent: () => true,
      operationIdFactory: () {
        factoryCalls++;
        return 'operation-b';
      },
    ).execute<void>(
      commandType: 'PAYMENT_CREATE',
      targetId: 'order-1',
      payload: const {
        'serviceOrderId': 'order-1',
        'method': 'PIX',
        'amountMinor': 100,
      },
      dispatch: (operationId) async {
        dispatched.add(operationId);
      },
      authoritativeCommit: (_, __) async {},
    );
    expect(dispatched, ['operation-a']);
    expect(factoryCalls, 0);
  });

  test('M2 COMPLETED remains terminal and equivalent action gets a new id',
      () async {
    final db = await _openV6();
    addTearDown(db.close);
    await _insertLegacy(db, lifecycle: 'COMPLETED');
    await SqliteDatabase.migrateV6ToV7(db);

    expect(
      CommandIntent.fromMap((await db.query('command_intents')).single)
          .lifecycle,
      CommandIntentLifecycle.completed,
    );
    final next = await CommandIntentLocalDataSource().getOrCreate(
      commandType: 'PAYMENT_CREATE',
      targetId: 'order-1',
      payload: const {
        'amountMinor': 100,
        'method': 'PIX',
        'serviceOrderId': 'order-1',
      },
      operationIdFactory: () => 'operation-b',
      executor: db,
    );
    expect(next.operationId, 'operation-b');
    expect(await db.query('command_intents'), hasLength(2));
  });

  test('M3 SENDING recovers to UNKNOWN without changing operationId', () async {
    final db = await _openV6();
    addTearDown(db.close);
    await _insertLegacy(db, lifecycle: 'SENDING');
    await SqliteDatabase.migrateV6ToV7(db);

    final store = CommandIntentLocalDataSource();
    var row = CommandIntent.fromMap((await db.query('command_intents')).single);
    expect(row.lifecycle, CommandIntentLifecycle.sending);
    await store.recoverInterruptedSending(executor: db);
    row = CommandIntent.fromMap((await db.query('command_intents')).single);
    expect(row.lifecycle, CommandIntentLifecycle.unknown);
    expect(row.operationId, 'operation-a');
    final reusable = await store.getOrCreate(
      commandType: 'PAYMENT_CREATE',
      targetId: 'order-1',
      payload: const {
        'amountMinor': 100,
        'method': 'PIX',
        'serviceOrderId': 'order-1',
      },
      operationIdFactory: () => 'must-not-be-used',
      executor: db,
    );
    expect(reusable.operationId, 'operation-a');
  });

  test('legacy Payment command types map to globally namespaced identities',
      () async {
    final db = await _openV6();
    addTearDown(db.close);
    await _insertLegacy(
      db,
      operationId: 'operation-create',
      commandType: 'CREATE',
      lifecycle: 'COMPLETED',
    );
    await _insertLegacy(
      db,
      operationId: 'operation-confirm',
      commandType: 'CONFIRM',
      lifecycle: 'COMPLETED',
    );
    await _insertLegacy(
      db,
      operationId: 'operation-cancel',
      commandType: 'CANCEL',
      lifecycle: 'COMPLETED',
    );
    await SqliteDatabase.migrateV6ToV7(db);
    expect(
      (await db.query('command_intents', orderBy: 'operation_id'))
          .map((row) => row['command_type']),
      ['PAYMENT_CANCEL', 'PAYMENT_CONFIRM', 'PAYMENT_CREATE'],
    );
  });

  test('M4 unsupported legacy command type fails closed', () async {
    final db = await _openV6();
    addTearDown(db.close);
    await _insertLegacy(db, commandType: 'REFUND');
    await _expectMigrationRollback(db);
  });

  test('M5 corrupt lifecycle fails closed', () async {
    final db = await _openV6(enforceLifecycle: false);
    addTearDown(db.close);
    await _insertLegacy(db, lifecycle: 'LOST');
    await _expectMigrationRollback(db);
  });

  test('M6 malformed canonical payload fails closed', () async {
    final db = await _openV6();
    addTearDown(db.close);
    await _insertLegacy(db, payload: '{"serviceOrderId":"order-1", bad}');
    await _expectMigrationRollback(db);
  });

  test('M6 contradictory unresolved identity fails closed', () async {
    final db = await _openV6(createIdentityIndex: false);
    addTearDown(db.close);
    await _insertLegacy(db, operationId: 'operation-a');
    await _insertLegacy(db, operationId: 'operation-b');
    await _expectMigrationRollback(db);
  });
}

const _payload =
    '{"amountMinor":100,"method":"PIX","serviceOrderId":"order-1"}';
const _createdAt = '2026-09-17T10:00:00.000Z';
const _updatedAt = '2026-09-17T10:05:00.000Z';

Future<Database> _openV6({
  bool enforceLifecycle = true,
  bool createIdentityIndex = true,
}) async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(version: 6, singleInstance: false),
  );
  await db.execute('''
    CREATE TABLE payment_command_intents (
      operation_id TEXT PRIMARY KEY,
      command_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      lifecycle_state TEXT NOT NULL${enforceLifecycle ? " CHECK (lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN', 'COMPLETED', 'REJECTED'))" : ''},
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  if (createIdentityIndex) {
    await db.execute('''
      CREATE UNIQUE INDEX payment_command_intents_unresolved_identity
      ON payment_command_intents(command_type, target_id, payload_json)
      WHERE lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')
    ''');
  }
  return db;
}

Future<void> _insertLegacy(
  Database db, {
  String operationId = 'operation-a',
  String commandType = 'CREATE',
  String lifecycle = 'UNKNOWN',
  String payload = _payload,
}) {
  return db.insert('payment_command_intents', {
    'operation_id': operationId,
    'command_type': commandType,
    'target_id': 'order-1',
    'payload_json': payload,
    'lifecycle_state': lifecycle,
    'created_at': _createdAt,
    'updated_at': _updatedAt,
  });
}

Future<void> _expectMigrationRollback(Database db) async {
  await expectLater(SqliteDatabase.migrateV6ToV7(db), throwsA(anything));
  expect(await _tableExists(db, 'payment_command_intents'), isTrue);
  expect(await _tableExists(db, 'command_intents'), isFalse);
}

Future<bool> _tableExists(Database db, String table) async {
  final rows = await db.query(
    'sqlite_master',
    columns: ['name'],
    where: "type = 'table' AND name = ?",
    whereArgs: [table],
  );
  return rows.isNotEmpty;
}
