import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  final dao = OutboxDao();
  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _schema(db);
  });
  tearDown(() => db.close());

  group('CREATE discard', () {
    test('discards every eligible operation and deletes entity atomically',
        () async {
      await db.insert('customers', {'id': 'customer-1', 'name': 'Local'});
      await _operation(db, 'create-1', 'CUSTOMER', 'customer-1');
      await _operation(db, 'create-2', 'CUSTOMER', 'customer-1');

      await dao.discardCreate(
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
        entityTable: 'customers',
        database: db,
      );

      expect(await db.query('customers'), isEmpty);
      final history = await db.query('outbox', orderBy: 'operation_id');
      expect(history.map((row) => row['status']), ['DISCARDED', 'DISCARDED']);
    });

    test('allows only definitively rejected fatal CREATE and preserves history',
        () async {
      await db.insert('customers', {'id': 'customer-fatal', 'name': 'Local'});
      await _operation(
        db,
        'fatal-create',
        'CUSTOMER',
        'customer-fatal',
        status: 'FAILED_FATAL',
        disposition: 'CONFIRMED',
      );
      await dao.discardCreate(
        entityType: 'CUSTOMER',
        entityId: 'customer-fatal',
        entityTable: 'customers',
        database: db,
      );
      expect(await db.query('customers'), isEmpty);
      expect((await db.query('outbox')).single['status'], 'DISCARDED');
    });

    test(
        'keeps historical SUPERSEDED rows unchanged while discarding active CREATE',
        () async {
      await db.insert('customers', {'id': 'customer-history', 'name': 'Local'});
      await _operation(
        db,
        'old-superseded',
        'CUSTOMER',
        'customer-history',
        status: 'SUPERSEDED',
        disposition: 'AMBIGUOUS',
      );
      await _operation(db, 'current-create', 'CUSTOMER', 'customer-history');
      await dao.discardCreate(
        entityType: 'CUSTOMER',
        entityId: 'customer-history',
        entityTable: 'customers',
        database: db,
      );
      final history = await db.query('outbox', orderBy: 'operation_id');
      expect(history.map((row) => row['status']), ['DISCARDED', 'SUPERSEDED']);
      expect(history.last['remote_disposition'], 'AMBIGUOUS');
    });

    for (final veto in [
      (status: 'SYNCED', disposition: 'CONFIRMED', op: 'CREATE'),
      (status: 'PROCESSING', disposition: 'AMBIGUOUS', op: 'CREATE'),
      (status: 'REQUIRES_ATTENTION', disposition: 'AMBIGUOUS', op: 'CREATE'),
      (status: 'REQUIRES_ATTENTION', disposition: 'CONFIRMED', op: 'CREATE'),
      (status: 'PENDING', disposition: 'UNSENT', op: 'UPDATE'),
      (status: 'PENDING', disposition: 'UNSENT', op: 'DELETE'),
      (status: 'FAILED_TRANSIENT', disposition: 'CONFIRMED', op: 'CREATE'),
    ]) {
      test('vetoes ${veto.status}/${veto.disposition}/${veto.op}', () async {
        await db.insert('customers', {'id': 'customer-1', 'name': 'Local'});
        await _operation(
          db,
          'veto-op',
          'CUSTOMER',
          'customer-1',
          status: veto.status,
          disposition: veto.disposition,
          type: veto.op,
        );
        await expectLater(
          dao.discardCreate(
            entityType: 'CUSTOMER',
            entityId: 'customer-1',
            entityTable: 'customers',
            database: db,
          ),
          throwsA(isA<OutboxTransitionException>()),
        );
        expect(await db.query('customers'), hasLength(1));
        expect((await db.query('outbox')).single['status'], veto.status);
      });
    }

    test('vetoes dependent Equipment and Customer rows', () async {
      await db.insert('customers', {'id': 'customer-1', 'name': 'Local'});
      await db.insert(
          'equipments', {'id': 'equipment-1', 'customer_id': 'customer-1'});
      await _operation(db, 'customer-create', 'CUSTOMER', 'customer-1');
      await expectLater(
        dao.discardCreate(
          entityType: 'CUSTOMER',
          entityId: 'customer-1',
          entityTable: 'customers',
          database: db,
        ),
        throwsA(isA<OutboxTransitionException>()),
      );
      expect((await db.query('outbox')).single['status'], 'PENDING');
      expect(await db.query('customers'), hasLength(1));
    });

    test('vetoes Equipment with ServiceOrder or PreAcquisition dependents',
        () async {
      for (final table in ['service_orders', 'pre_acquisitions']) {
        await db.delete('outbox');
        await db.delete('equipments');
        await db.delete('service_orders');
        await db.delete('pre_acquisitions');
        await db.insert('equipments', {'id': 'equipment-1'});
        await db.insert(table, {
          'id': 'dependent-1',
          'equipment_id': 'equipment-1',
        });
        await _operation(db, 'equipment-create', 'EQUIPMENT', 'equipment-1');
        await expectLater(
          dao.discardCreate(
            entityType: 'EQUIPMENT',
            entityId: 'equipment-1',
            entityTable: 'equipments',
            database: db,
          ),
          throwsA(isA<OutboxTransitionException>()),
        );
      }
    });

    test(
        'rolls back operation reclassification if entity deletion affects zero rows',
        () async {
      await _operation(db, 'missing-create', 'CUSTOMER', 'missing-customer');
      await expectLater(
        dao.discardCreate(
          entityType: 'CUSTOMER',
          entityId: 'missing-customer',
          entityTable: 'customers',
          database: db,
        ),
        throwsA(isA<OutboxTransitionException>()),
      );
      expect((await db.query('outbox')).single['status'], 'PENDING');
    });
  });

  group('SUPERSEDED', () {
    test('creates replacement UUID and updates entity in one transaction',
        () async {
      await db.insert('customers', {'id': 'customer-1', 'name': 'Before'});
      await _operation(db, 'old-op', 'CUSTOMER', 'customer-1');
      final newId = await dao.supersede(
        oldOperationId: 'old-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
        oldStatus: 'PENDING',
        oldDisposition: RemoteDisposition.unsent,
        replacement: _item('placeholder', 'CUSTOMER', 'customer-1'),
        entityTable: 'customers',
        localUpdate: {'name': 'After'},
        database: db,
      );
      expect(newId, isNot('placeholder'));
      expect(newId, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect((await db.query('customers')).single['name'], 'After');
      final history = await db.query('outbox', orderBy: 'operation_id');
      expect(history, hasLength(2));
      expect(
          (await db.query('outbox',
                  where: 'operation_id = ?', whereArgs: ['old-op']))
              .single['status'],
          'SUPERSEDED');
      expect(
          (await db.query('outbox',
                  where: 'operation_id = ?', whereArgs: [newId]))
              .single['status'],
          'PENDING');
    });

    test(
        'rejects identity, state, and ambiguous changes without partial writes',
        () async {
      await db.insert('customers', {'id': 'customer-1', 'name': 'Before'});
      await _operation(db, 'old-op', 'CUSTOMER', 'customer-1');
      await expectLater(
        dao.supersede(
          oldOperationId: 'old-op',
          entityType: 'CUSTOMER',
          entityId: 'different-id',
          oldStatus: 'PENDING',
          oldDisposition: RemoteDisposition.unsent,
          replacement: _item('placeholder', 'CUSTOMER', 'different-id'),
          entityTable: 'customers',
          localUpdate: {'name': 'After'},
          database: db,
        ),
        throwsA(isA<OutboxTransitionException>()),
      );
      await expectLater(
        dao.supersede(
          oldOperationId: 'old-op',
          entityType: 'CUSTOMER',
          entityId: 'customer-1',
          oldStatus: 'PROCESSING',
          oldDisposition: RemoteDisposition.ambiguous,
          replacement: _item('placeholder', 'CUSTOMER', 'customer-1'),
          entityTable: 'customers',
          localUpdate: {'name': 'After'},
          database: db,
        ),
        throwsA(isA<OutboxTransitionException>()),
      );
      expect(await db.query('outbox'), hasLength(1));
      expect((await db.query('customers')).single['name'], 'Before');
    });

    test(
        'rolls back old state and replacement when entity update affects zero rows',
        () async {
      await _operation(db, 'old-op', 'CUSTOMER', 'missing-customer');
      await expectLater(
        dao.supersede(
          oldOperationId: 'old-op',
          entityType: 'CUSTOMER',
          entityId: 'missing-customer',
          oldStatus: 'PENDING',
          oldDisposition: RemoteDisposition.unsent,
          replacement: _item('placeholder', 'CUSTOMER', 'missing-customer'),
          entityTable: 'customers',
          localUpdate: {'name': 'After'},
          database: db,
        ),
        throwsA(isA<OutboxTransitionException>()),
      );
      final rows = await db.query('outbox');
      expect(rows, hasLength(1));
      expect(rows.single['status'], 'PENDING');
    });
  });
}

OutboxItem _item(String id, String type, String entityId) => OutboxItem(
      operationId: id,
      entityType: type,
      entityId: entityId,
      operationType: 'CREATE',
      payload: {'name': 'After'},
      createdAt: '2026-01-01T00:00:00Z',
    );

Future<void> _operation(
  Database db,
  String id,
  String entityType,
  String entityId, {
  String status = 'PENDING',
  String disposition = 'UNSENT',
  String type = 'CREATE',
}) async {
  await db.insert('outbox', {
    'operation_id': id,
    'entity_type': entityType,
    'entity_id': entityId,
    'operation_type': type,
    'payload': '{}',
    'created_at': '2026-01-01T00:00:00Z',
    'attempt_count': 0,
    'status': status,
    'remote_disposition': disposition,
  });
}

Future<void> _schema(Database db) async {
  await db.execute('''CREATE TABLE outbox (
    operation_id TEXT PRIMARY KEY, device_id TEXT, user_id TEXT,
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    operation_type TEXT NOT NULL, payload TEXT NOT NULL,
    created_at TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at TEXT, next_retry_at TEXT, last_error TEXT,
    status TEXT NOT NULL, remote_disposition TEXT NOT NULL)''');
  await db.execute('CREATE TABLE customers (id TEXT PRIMARY KEY, name TEXT)');
  await db.execute(
      'CREATE TABLE equipments (id TEXT PRIMARY KEY, customer_id TEXT)');
  await db.execute(
      'CREATE TABLE service_orders (id TEXT PRIMARY KEY, customer_id TEXT, equipment_id TEXT)');
  await db.execute(
      'CREATE TABLE pre_acquisitions (id TEXT PRIMARY KEY, equipment_id TEXT)');
  await db.execute(
      'CREATE TABLE service_order_items (id TEXT PRIMARY KEY, service_order_id TEXT)');
}
