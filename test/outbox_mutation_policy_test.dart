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
        disposition: 'CONFIRMED',
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
      expect(history.last['remote_disposition'], 'CONFIRMED');
    });

    for (final veto in [
      (status: 'SYNCED', disposition: 'CONFIRMED', op: 'CREATE'),
      (status: 'PROCESSING', disposition: 'AMBIGUOUS', op: 'CREATE'),
      (status: 'REQUIRES_ATTENTION', disposition: 'AMBIGUOUS', op: 'CREATE'),
      (status: 'REQUIRES_ATTENTION', disposition: 'CONFIRMED', op: 'CREATE'),
      (status: 'PENDING', disposition: 'UNSENT', op: 'UPDATE'),
      (status: 'PENDING', disposition: 'UNSENT', op: 'DELETE'),
      (status: 'FAILED_TRANSIENT', disposition: 'CONFIRMED', op: 'CREATE'),
      (status: 'SUPERSEDED', disposition: 'AMBIGUOUS', op: 'CREATE'),
      (status: 'DISCARDED', disposition: 'AMBIGUOUS', op: 'CREATE'),
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

    test('vetoes every direct dependent reference and rolls back atomically',
        () async {
      final references = [
        (entityType: 'CUSTOMER', entityTable: 'customers', dependency: 'equipments', column: 'customer_id'),
        (entityType: 'CUSTOMER', entityTable: 'customers', dependency: 'service_orders', column: 'customer_id'),
        (entityType: 'CUSTOMER', entityTable: 'customers', dependency: 'pre_acquisitions', column: 'customer_id'),
        (entityType: 'CUSTOMER', entityTable: 'customers', dependency: 'equipment_acquisitions', column: 'customer_id'),
        (entityType: 'CUSTOMER', entityTable: 'customers', dependency: 'payments', column: 'customer_id'),
        (entityType: 'EQUIPMENT', entityTable: 'equipments', dependency: 'service_orders', column: 'equipment_id'),
        (entityType: 'EQUIPMENT', entityTable: 'equipments', dependency: 'pre_acquisitions', column: 'equipment_id'),
        (entityType: 'EQUIPMENT', entityTable: 'equipments', dependency: 'equipment_acquisitions', column: 'equipment_id'),
        (entityType: 'SERVICE_ORDER', entityTable: 'service_orders', dependency: 'service_order_items', column: 'service_order_id'),
        (entityType: 'SERVICE_ORDER', entityTable: 'service_orders', dependency: 'pre_acquisitions', column: 'service_order_id'),
        (entityType: 'SERVICE_ORDER', entityTable: 'service_orders', dependency: 'equipment_acquisitions', column: 'service_order_id'),
        (entityType: 'SERVICE_ORDER', entityTable: 'service_orders', dependency: 'payments', column: 'service_order_id'),
        (entityType: 'SERVICE_ORDER', entityTable: 'service_orders', dependency: 'inventory_movements', column: 'service_order_id'),
        (entityType: 'SERVICE_ORDER', entityTable: 'service_orders', dependency: 'command_intents', column: 'target_id'),
        (entityType: 'PRE_ACQUISITION', entityTable: 'pre_acquisitions', dependency: 'equipment_acquisitions', column: 'client_pre_acquisition_id'),
        (entityType: 'PRE_ACQUISITION', entityTable: 'pre_acquisitions', dependency: 'command_intents', column: 'target_id'),
      ];
      for (final ref in references) {
        await db.delete('outbox');
        await db.delete('equipment_acquisitions');
        await db.delete('payments');
        await db.delete('inventory_movements');
        await db.delete('command_intents');
        await db.delete('service_order_items');
        await db.delete('pre_acquisitions');
        await db.delete('service_orders');
        await db.delete('equipments');
        await db.delete('customers');
        final entityId = 'entity-${ref.entityType}';
        final entityValues = switch (ref.entityType) {
          'CUSTOMER' => {'id': entityId, 'name': 'Local'},
          'EQUIPMENT' => {'id': entityId, 'customer_id': 'customer-1'},
          'SERVICE_ORDER' => {
              'id': entityId,
              'equipment_id': 'equipment-1',
            },
          _ => {
              'id': entityId,
              'equipment_id': 'equipment-1',
              'customer_id': 'customer-1',
              'organization_id': 'org-1',
              'purpose': 'RESALE',
              'status': 'PENDING_EVALUATION',
              'created_at': '2026-01-01T00:00:00Z',
              'evaluation_deadline': '2026-02-01T00:00:00Z',
            },
        };
        await db.insert(ref.entityTable, entityValues);
        if (ref.dependency == 'pre_acquisitions') {
          await db.insert('pre_acquisitions', {
            'id': 'dependent-pre-acquisition',
            'equipment_id': 'equipment-1',
            'customer_id': 'customer-1',
            'organization_id': 'org-1',
            'service_order_id': ref.column == 'service_order_id' ? entityId : null,
            'purpose': 'RESALE',
            'status': 'PENDING_EVALUATION',
            'created_at': '2026-01-01T00:00:00Z',
            'evaluation_deadline': '2026-02-01T00:00:00Z',
            if (ref.column != 'service_order_id') ref.column: entityId,
          });
        } else if (ref.dependency == 'equipment_acquisitions') {
          await db.insert('equipment_acquisitions', {
            'id': 'dependent-acquisition',
            'equipment_id': 'equipment-1',
            'customer_id': 'customer-1',
            'organization_id': 'org-1',
            'service_order_id': ref.column == 'service_order_id' ? entityId : null,
            'source': ref.column == 'service_order_id' ? 'SERVICE_ORDER' : 'DIRECT_OFFER',
            'client_pre_acquisition_id': ref.column == 'client_pre_acquisition_id' ? entityId : null,
            'purpose': 'RESALE',
            'status': 'PENDING',
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00Z',
            if (ref.column != 'service_order_id') ref.column: entityId,
          });
        } else if (ref.dependency == 'command_intents') {
          await db.insert('command_intents', {
            'operation_id': 'dependent-command-intent',
            'command_type': ref.entityType == 'SERVICE_ORDER'
                ? 'SERVICE_ORDER_QUOTE_PUBLISH'
                : 'EQUIPMENT_ACQUISITION_CREATE',
            'target_id': entityId,
            'payload_json': '{}',
            'lifecycle_state': 'PENDING',
            'created_at': '2026-01-01T00:00:00Z',
            'updated_at': '2026-01-01T00:00:00Z',
          });
        } else {
          await db.insert(ref.dependency, {
            'id': 'dependent-${ref.dependency}',
            ref.column: entityId,
          });
        }
        await _operation(
          db,
          'create-${ref.entityType}',
          ref.entityType,
          entityId,
        );

        await expectLater(
          dao.discardCreate(
            entityType: ref.entityType,
            entityId: entityId,
            entityTable: ref.entityTable,
            database: db,
          ),
          throwsA(isA<OutboxTransitionException>()),
        );
        expect((await db.query('outbox')).single['status'], 'PENDING');
        expect(await db.query(ref.entityTable), hasLength(1));
      }
    });

    test('CUSTOMER remains when a PreAcquisition references its customer',
        () async {
      await db.insert('customers', {'id': 'customer-1', 'name': 'Local'});
      await db.insert('pre_acquisitions', {
        'id': 'pre-1',
        'equipment_id': 'equipment-1',
        'customer_id': 'customer-1',
        'organization_id': 'org-1',
        'purpose': 'RESALE',
        'status': 'PENDING_EVALUATION',
        'created_at': '2026-01-01T00:00:00Z',
        'evaluation_deadline': '2026-02-01T00:00:00Z',
      });
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
        if (table == 'pre_acquisitions') {
          await db.insert('pre_acquisitions', {
            'id': 'dependent-1',
            'equipment_id': 'equipment-1',
            'customer_id': 'customer-1',
            'organization_id': 'org-1',
            'purpose': 'RESALE',
            'status': 'PENDING_EVALUATION',
            'created_at': '2026-01-01T00:00:00Z',
            'evaluation_deadline': '2026-02-01T00:00:00Z',
          });
        } else {
          await db.insert(table, {
            'id': 'dependent-1',
            'equipment_id': 'equipment-1',
          });
        }
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

    test('rejects a mismatched entity type and table before writing', () async {
      await db.insert('customers', {'id': 'customer-1', 'name': 'Before'});
      await db.insert('equipments', {'id': 'customer-1'});
      await _operation(db, 'old-op', 'CUSTOMER', 'customer-1');

      await expectLater(
        dao.supersede(
          oldOperationId: 'old-op',
          entityType: 'CUSTOMER',
          entityId: 'customer-1',
          oldStatus: 'PENDING',
          oldDisposition: RemoteDisposition.unsent,
          replacement: _item('placeholder', 'CUSTOMER', 'customer-1'),
          entityTable: 'equipments',
          localUpdate: {'model': 'Corrupted'},
          database: db,
        ),
        throwsArgumentError,
      );
      expect((await db.query('customers')).single['name'], 'Before');
      expect((await db.query('equipments')).single['model'], isNull);
      expect((await db.query('outbox')).single['status'], 'PENDING');
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
  await db.execute('''CREATE TABLE pre_acquisitions (
        id TEXT PRIMARY KEY, equipment_id TEXT NOT NULL, customer_id TEXT NOT NULL,
        organization_id TEXT NOT NULL, service_order_id TEXT, purpose TEXT NOT NULL,
        status TEXT NOT NULL, offered_amount_minor INTEGER, notes TEXT,
        created_at TEXT NOT NULL, evaluation_deadline TEXT NOT NULL,
        evaluated_at TEXT, resolution_reason TEXT)''');
  await db.execute('''CREATE TABLE equipment_acquisitions (
    id TEXT PRIMARY KEY, equipment_id TEXT NOT NULL, customer_id TEXT NOT NULL,
    organization_id TEXT NOT NULL, service_order_id TEXT, source TEXT NOT NULL CHECK (
      source IN ('SERVICE_ORDER', 'DIRECT_OFFER')),
    client_pre_acquisition_id TEXT, purpose TEXT NOT NULL, status TEXT NOT NULL,
    offered_amount_minor INTEGER, consent_method TEXT, authorized_at TEXT,
    rejected_at TEXT, cancelled_at TEXT, completed_at TEXT, notes TEXT,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    CHECK ((source = 'SERVICE_ORDER' AND service_order_id IS NOT NULL) OR
      (source = 'DIRECT_OFFER' AND service_order_id IS NULL)))''');
  await db.execute(
      'CREATE TABLE service_order_items (id TEXT PRIMARY KEY, service_order_id TEXT)');
  await db.execute(
      'CREATE TABLE payments (id TEXT PRIMARY KEY, customer_id TEXT, service_order_id TEXT)');
  await db.execute(
      'CREATE TABLE inventory_movements (id TEXT PRIMARY KEY, service_order_id TEXT)');
  await db.execute('''CREATE TABLE command_intents (
    operation_id TEXT PRIMARY KEY, command_type TEXT NOT NULL,
    target_id TEXT NOT NULL, payload_json TEXT NOT NULL,
    lifecycle_state TEXT NOT NULL, created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL)''');
}
