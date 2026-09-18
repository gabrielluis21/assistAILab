import 'dart:async';

import 'package:assistailab/core/commands/command_executor.dart';
import 'package:assistailab/core/commands/command_failure.dart';
import 'package:assistailab/core/commands/command_intent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late CommandIntentLocalDataSource intents;

  setUp(() async {
    db = await _openDatabase();
    intents = CommandIntentLocalDataSource(
      nowUtc: () => DateTime.utc(2026, 9, 18),
    );
  });

  tearDown(() => db.close());

  test('new intent is PENDING, dispatch is SENDING and success is atomic',
      () async {
    final pending = await intents.getOrCreate(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-1',
      payload: const {'value': 1},
      operationIdFactory: () => 'operation-1',
      executor: db,
    );
    expect(pending.lifecycle, CommandIntentLifecycle.pending);

    final result = await _executor(db, intents, () => 'unused').execute<String>(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-1',
      payload: const {'value': 1},
      dispatch: (operationId) async {
        expect(operationId, 'operation-1');
        expect(await _lifecycle(db, operationId), 'SENDING');
        return 'authoritative';
      },
      authoritativeCommit: (executor, authoritative) => executor.insert(
        'authoritative_results',
        {'id': 'result-1', 'value': authoritative},
      ),
    );

    expect(result, 'authoritative');
    expect(await _lifecycle(db, 'operation-1'), 'COMPLETED');
    expect((await db.query('authoritative_results')).single['value'], result);
  });

  test('authoritative persistence failure cannot leave false COMPLETED',
      () async {
    await expectLater(
      _executor(db, intents, () => 'operation-1').execute<String>(
        commandType: 'TEST_EXECUTE',
        targetId: 'target-1',
        payload: const {'value': 1},
        dispatch: (_) async => 'authoritative',
        authoritativeCommit: (executor, authoritative) async {
          await executor.insert(
            'authoritative_results',
            {'id': 'result-1', 'value': authoritative},
          );
          throw StateError('local commit failed');
        },
      ),
      throwsStateError,
    );
    expect(await db.query('authoritative_results'), isEmpty);
    expect(await _lifecycle(db, 'operation-1'), 'UNKNOWN');
  });

  final failures = <String, ({Object error, String lifecycle})>{
    'timeout': (
      error: TimeoutException('lost'),
      lifecycle: 'UNKNOWN',
    ),
    'transport': (error: Exception('connection reset'), lifecycle: 'UNKNOWN'),
    'http 408': (
      error: const CommandException(408, 'REQUEST_TIMEOUT'),
      lifecycle: 'UNKNOWN',
    ),
    'http 429': (
      error: const CommandException(429, 'RATE_LIMITED'),
      lifecycle: 'UNKNOWN',
    ),
    'uncertain 5xx': (
      error: const CommandException(503, 'UNAVAILABLE'),
      lifecycle: 'UNKNOWN',
    ),
    'idempotency in progress': (
      error: const CommandException(409, 'IDEMPOTENCY_IN_PROGRESS'),
      lifecycle: 'UNKNOWN',
    ),
    'idempotency state conflict': (
      error: const CommandException(409, 'IDEMPOTENCY_STATE_CONFLICT'),
      lifecycle: 'UNKNOWN',
    ),
    'ordinary 409': (
      error: const CommandException(409, 'BUSINESS_CONFLICT'),
      lifecycle: 'REJECTED',
    ),
    'key reuse': (
      error: const CommandException(409, 'IDEMPOTENCY_KEY_REUSE'),
      lifecycle: 'REJECTED',
    ),
  };
  for (final entry in failures.entries) {
    test('${entry.key} has frozen failure classification', () async {
      await expectLater(
        _executor(db, intents, () => 'operation-1').execute<void>(
          commandType: 'TEST_EXECUTE',
          targetId: 'target-1',
          payload: const {'value': 1},
          dispatch: (_) async => throw entry.value.error,
          authoritativeCommit: (_, __) async {},
        ),
        throwsA(same(entry.value.error)),
      );
      expect(await _lifecycle(db, 'operation-1'), entry.value.lifecycle);
    });
  }

  test('UNKNOWN retry reuses operationId and resolved action gets a new one',
      () async {
    final dispatched = <String>[];
    var attempts = 0;
    var factoryCalls = 0;
    final executor = _executor(
      db,
      intents,
      () => 'operation-${++factoryCalls}',
    );
    Future<String> dispatch(String operationId) async {
      dispatched.add(operationId);
      if (attempts++ == 0) throw TimeoutException('lost');
      return 'ok';
    }

    await expectLater(
      executor.execute<String>(
        commandType: 'TEST_EXECUTE',
        targetId: 'target-1',
        payload: const {'value': 1},
        dispatch: dispatch,
        authoritativeCommit: (_, __) async {},
      ),
      throwsA(isA<TimeoutException>()),
    );
    await executor.execute<String>(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-1',
      payload: const {'value': 1},
      dispatch: dispatch,
      authoritativeCommit: (_, __) async {},
    );
    await executor.execute<String>(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-1',
      payload: const {'value': 1},
      dispatch: dispatch,
      authoritativeCommit: (_, __) async {},
    );

    expect(dispatched, ['operation-1', 'operation-1', 'operation-2']);
    expect(factoryCalls, 2);
  });

  test('operationId collision with another payload fails closed', () async {
    await intents.getOrCreate(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-1',
      payload: const {'value': 1},
      operationIdFactory: () => 'fixed-operation',
      executor: db,
    );
    await expectLater(
      intents.getOrCreate(
        commandType: 'TEST_EXECUTE',
        targetId: 'target-1',
        payload: const {'value': 2},
        operationIdFactory: () => 'fixed-operation',
        executor: db,
      ),
      throwsA(isA<CommandIntentIdentityException>()),
    );
  });

  test('canonical identity sorts losslessly and rejects floating authority',
      () {
    expect(
      canonicalCommandPayload(const {
        'z': [true, null, 2],
        'a': {'second': 'b', 'first': 1},
      }),
      '{"a":{"first":1,"second":"b"},"z":[true,null,2]}',
    );
    expect(
      () => canonicalCommandPayload(const {'amountMinor': 1.5}),
      throwsFormatException,
    );
  });

  test('interrupted SENDING recovery becomes UNKNOWN', () async {
    final intent = await intents.getOrCreate(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-1',
      payload: const {'value': 1},
      operationIdFactory: () => 'operation-1',
      executor: db,
    );
    await intents.setLifecycle(
      intent.operationId,
      CommandIntentLifecycle.sending,
      executor: db,
    );
    await intents.recoverInterruptedSending(executor: db);
    expect(await _lifecycle(db, intent.operationId), 'UNKNOWN');
  });

  test('stale binding after response cannot commit or redirect authority',
      () async {
    final dbB = await _openDatabase();
    addTearDown(dbB.close);
    await dbB.insert(
      'authoritative_results',
      {'id': 'result-b', 'value': 'authoritative-b'},
    );
    final entered = Completer<void>();
    final response = Completer<String>();
    var current = true;
    final pending = CommandExecutor(
      intentRepository: intents,
      database: db,
      isBindingCurrent: () => current,
      operationIdFactory: () => 'operation-a',
    ).execute<String>(
      commandType: 'TEST_EXECUTE',
      targetId: 'target-a',
      payload: const {'value': 1},
      dispatch: (_) {
        entered.complete();
        return response.future;
      },
      authoritativeCommit: (executor, authoritative) => executor.insert(
        'authoritative_results',
        {'id': 'result-a', 'value': authoritative},
      ),
    );

    await entered.future;
    current = false;
    response.complete('late-a');
    await expectLater(pending, throwsStateError);
    expect(await db.query('authoritative_results'), isEmpty);
    expect(await _lifecycle(db, 'operation-a'), 'SENDING');
    expect(
      await dbB.query('authoritative_results'),
      [containsPair('value', 'authoritative-b')],
    );
  });
}

CommandExecutor _executor(
  Database db,
  CommandIntentRepository intents,
  String Function() operationIdFactory,
) {
  return CommandExecutor(
    intentRepository: intents,
    database: db,
    isBindingCurrent: () => true,
    operationIdFactory: operationIdFactory,
  );
}

Future<String?> _lifecycle(Database db, String operationId) async {
  final rows = await db.query(
    'command_intents',
    columns: ['lifecycle_state'],
    where: 'operation_id = ?',
    whereArgs: [operationId],
  );
  return rows.single['lifecycle_state'] as String?;
}

Future<Database> _openDatabase() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute('''
    CREATE TABLE command_intents (
      operation_id TEXT PRIMARY KEY,
      command_type TEXT NOT NULL,
      target_id TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      lifecycle_state TEXT NOT NULL CHECK (
        lifecycle_state IN (
          'PENDING', 'SENDING', 'UNKNOWN', 'COMPLETED', 'REJECTED'
        )
      ),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE UNIQUE INDEX command_intents_unresolved_identity
    ON command_intents(command_type, target_id, payload_json)
    WHERE lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')
  ''');
  await db.execute('''
    CREATE TABLE authoritative_results (
      id TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )
  ''');
  return db;
}
