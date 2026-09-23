import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/network/api_client.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
import 'package:assistailab/core/sync/sync_projection_applier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final class _HttpClient extends http.BaseClient {
  final Future<http.Response> Function(http.Request request) handler;

  _HttpClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await handler(request as http.Request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    await _createSchema(db);
  });

  tearDown(() => db.close());

  group('FE03-P07-A bootstrap pending-mutation policy', () {
    test('bootstrap without pending mutations performs normal replacement',
        () async {
      await _insertCustomer(db, id: 'removed', name: 'Old local');

      await SyncProjectionApplier.replaceBootstrap(db, [
        _customerRecord('remote', 'Remote snapshot'),
        _equipmentRecord('equipment-remote', model: 'Remote model'),
      ]);

      expect(await _customerName(db, 'removed'), isNull);
      expect(await _customerName(db, 'remote'), 'Remote snapshot');
      expect(await _equipmentModel(db, 'equipment-remote'), 'Remote model');
    });

    test('bootstrap preserves Customer with unresolved local mutation',
        () async {
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertCustomer(db, id: 'removed', name: 'Old projection');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
      );

      await SyncProjectionApplier.replaceBootstrap(db, [
        _customerRecord('customer-1', 'Remote stale'),
        _customerRecord('customer-2', 'Remote current'),
      ]);

      expect(await _customerName(db, 'customer-1'), 'Local pending');
      expect(await _customerName(db, 'customer-2'), 'Remote current');
      expect(await _customerName(db, 'removed'), isNull);
      expect(await _outboxStatus(db, 'customer-op'), 'PENDING');
    });

    test('bootstrap preserves Equipment with unresolved local mutation',
        () async {
      await _insertEquipment(
        db,
        id: 'equipment-1',
        model: 'Local pending',
      );
      await _insertOutbox(
        db,
        operationId: 'equipment-op',
        entityType: 'EQUIPMENT',
        entityId: 'equipment-1',
        status: 'FAILED',
      );

      await SyncProjectionApplier.replaceBootstrap(db, [
        _equipmentRecord('equipment-1', model: 'Remote stale'),
      ]);

      expect(await _equipmentModel(db, 'equipment-1'), 'Local pending');
      expect(await _outboxStatus(db, 'equipment-op'), 'FAILED');
    });

    test('bootstrap preserves Service Order aggregate and items', () async {
      await _insertServiceOrder(db, id: 'order-1', diagnosis: 'Local pending');
      await _insertServiceOrderItem(
        db,
        id: 'item-local',
        serviceOrderId: 'order-1',
        description: 'Local item',
      );
      await _insertOutbox(
        db,
        operationId: 'item-op',
        entityType: 'SERVICE_ORDER_ITEM',
        entityId: 'item-local',
        payload: {'serviceOrderId': 'order-1'},
        status: 'PROCESSING',
      );

      await SyncProjectionApplier.replaceBootstrap(db, [
        _serviceOrderRecord('order-1', diagnosis: 'Remote stale'),
      ]);

      expect(await _orderDiagnosis(db, 'order-1'), 'Local pending');
      expect(await _orderItemDescriptions(db, 'order-1'), ['Local item']);
      expect(await _outboxStatus(db, 'item-op'), 'PROCESSING');
    });

    test('bootstrap preserves multiple pending entity types together',
        () async {
      await _insertCustomer(db, id: 'customer-1', name: 'Local customer');
      await _insertEquipment(db, id: 'equipment-1', model: 'Local equipment');
      await _insertServiceOrder(db, id: 'order-1', diagnosis: 'Local order');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
        status: 'CONFLICT',
      );
      await _insertOutbox(
        db,
        operationId: 'equipment-op',
        entityType: 'EQUIPMENT',
        entityId: 'equipment-1',
        status: 'REQUIRES_ATTENTION',
      );
      await _insertOutbox(
        db,
        operationId: 'order-op',
        entityType: 'SERVICE_ORDER',
        entityId: 'order-1',
      );

      await SyncProjectionApplier.replaceBootstrap(db, [
        _customerRecord('customer-1', 'Remote customer'),
        _equipmentRecord('equipment-1', model: 'Remote equipment'),
        _serviceOrderRecord('order-1', diagnosis: 'Remote order'),
      ]);

      expect(await _customerName(db, 'customer-1'), 'Local customer');
      expect(await _equipmentModel(db, 'equipment-1'), 'Local equipment');
      expect(await _orderDiagnosis(db, 'order-1'), 'Local order');
      expect((await db.query('outbox')).length, 3);
    });

    test('bootstrap commits cursor while preserving pending mutation',
        () async {
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
      );
      final engine = SyncEngine(
        apiClient: _api((request) async {
          expect(request.url.path, '/sync/bootstrap');
          return http.Response(
            jsonEncode({
              'contractVersion': 2,
              'bootstrapCursor': '10',
              'records': [_customerRecord('customer-1', 'Remote stale')],
              'complete': true,
              'continuationToken': null,
              'bootstrapProof': 'proof-10',
            }),
            200,
          );
        }),
      );

      await engine.ensureV2Bootstrap(lease: _lease(db));

      expect(await _customerName(db, 'customer-1'), 'Local pending');
      expect(await engine.getLocalCursor(executor: db), '10');
      expect(await _metadata(db, 'sync_bootstrap_proof'), 'proof-10');
      expect(await _outboxStatus(db, 'customer-op'), 'PENDING');
    });
  });

  group('FE03-P07-A incremental pending-mutation policy', () {
    test('Customer and Equipment without pending mutations apply normally',
        () async {
      await SyncProjectionApplier.applyChange(
        db,
        _updateChange(_customerRecord('customer-1', 'Remote customer')),
      );
      await SyncProjectionApplier.applyChange(
        db,
        _updateChange(
          _equipmentRecord('equipment-1', model: 'Remote equipment'),
        ),
      );

      expect(await _customerName(db, 'customer-1'), 'Remote customer');
      expect(await _equipmentModel(db, 'equipment-1'), 'Remote equipment');
    });

    test('stale Customer projection cannot replace local pending state',
        () async {
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
      );

      await expectLater(
        SyncProjectionApplier.applyChange(
          db,
          _updateChange(_customerRecord('customer-1', 'Remote stale')),
        ),
        throwsA(_pendingMutationException),
      );

      expect(await _customerName(db, 'customer-1'), 'Local pending');
      expect(await _outboxStatus(db, 'customer-op'), 'PENDING');
    });

    test('stale Equipment projection cannot replace local pending state',
        () async {
      await _insertEquipment(db, id: 'equipment-1', model: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'equipment-op',
        entityType: 'EQUIPMENT',
        entityId: 'equipment-1',
      );

      await expectLater(
        SyncProjectionApplier.applyChange(
          db,
          _updateChange(
            _equipmentRecord('equipment-1', model: 'Remote stale'),
          ),
        ),
        throwsA(_pendingMutationException),
      );

      expect(await _equipmentModel(db, 'equipment-1'), 'Local pending');
      expect(await _outboxStatus(db, 'equipment-op'), 'PENDING');
    });

    test('remote delete remains deferred without choosing a conflict winner',
        () async {
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
        operationType: 'UPDATE',
      );

      await expectLater(
        SyncProjectionApplier.applyChange(db, {
          'entityType': 'CUSTOMER',
          'entityId': 'customer-1',
          'operationType': 'DELETE',
          'data': {
            'id': 'customer-1',
            'deleted': true,
            'contractVersion': 2,
            'projectionRevision': '2',
          },
        }),
        throwsA(_pendingMutationException),
      );

      expect(await _customerName(db, 'customer-1'), 'Local pending');
      expect(await _outboxStatus(db, 'customer-op'), 'PENDING');
    });

    test('confirmed mutation is released for later convergence', () async {
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
      );

      await SyncProjectionApplier.replaceBootstrap(db, [
        _customerRecord('customer-1', 'Remote stale'),
      ]);
      expect(await _customerName(db, 'customer-1'), 'Local pending');

      await db.update(
        'outbox',
        {'status': 'SYNCED'},
        where: 'operation_id = ?',
        whereArgs: ['customer-op'],
      );
      await SyncProjectionApplier.applyChange(
        db,
        _updateChange(_customerRecord('customer-1', 'Server confirmed')),
      );

      expect(await _customerName(db, 'customer-1'), 'Server confirmed');
      expect(await _outboxStatus(db, 'customer-op'), 'SYNCED');
    });

    test('pending change rolls back the complete pull page and cursor',
        () async {
      await _activateV2(db, cursor: '1');
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
      );
      final engine = SyncEngine(
        apiClient: _api((request) async => http.Response(
              jsonEncode({
                'nextCursor': '2',
                'changes': [
                  _updateChange(_customerRecord('other', 'Must roll back')),
                  _updateChange(
                    _customerRecord('customer-1', 'Remote stale'),
                  ),
                ],
              }),
              200,
            )),
      );

      await expectLater(
        engine.pullIncrementalChanges(lease: _lease(db)),
        throwsA(_pendingMutationException),
      );

      expect(await _customerName(db, 'other'), isNull);
      expect(await _customerName(db, 'customer-1'), 'Local pending');
      expect(await engine.getLocalCursor(executor: db), '1');
      expect(await _outboxStatus(db, 'customer-op'), 'PENDING');
    });
  });

  group('FE03-P07-A concurrency, session and tenant boundaries', () {
    test('concurrent Push keeps PROCESSING mutation protected from Pull',
        () async {
      await _activateV2(db, cursor: '1');
      await _insertCustomer(db, id: 'customer-1', name: 'Local pending');
      await _insertOutbox(
        db,
        operationId: 'customer-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-1',
      );
      final pushStarted = Completer<void>();
      final finishPush = Completer<http.Response>();
      final engine = SyncEngine(
        apiClient: _api((request) {
          if (request.url.path == '/sync/push') {
            pushStarted.complete();
            return finishPush.future;
          }
          return Future.value(http.Response(
            jsonEncode({
              'nextCursor': '2',
              'changes': [
                _updateChange(_customerRecord('customer-1', 'Remote stale')),
              ],
            }),
            200,
          ));
        }),
        outboxDao: OutboxDao(),
      );

      final push = engine.pushPendingOutbox(lease: _lease(db));
      await pushStarted.future;
      expect(await _outboxStatus(db, 'customer-op'), 'PROCESSING');

      await expectLater(
        engine.pullIncrementalChanges(lease: _lease(db)),
        throwsA(_pendingMutationException),
      );
      expect(await _customerName(db, 'customer-1'), 'Local pending');
      expect(await engine.getLocalCursor(executor: db), '1');

      finishPush.complete(http.Response(
        jsonEncode({
          'results': [
            {'operationId': 'customer-op', 'status': 'SYNCED'},
          ],
        }),
        200,
      ));
      expect((await push).syncedCount, 1);
      expect(await _outboxStatus(db, 'customer-op'), 'SYNCED');
    });

    test('late Pull response after logout cannot mutate old or new tenant',
        () async {
      await _activateV2(db, cursor: '1');
      await _insertCustomer(db, id: 'customer-a', name: 'Tenant A local');
      await _insertOutbox(
        db,
        operationId: 'customer-a-op',
        entityType: 'CUSTOMER',
        entityId: 'customer-a',
      );
      final tenantBDirectory =
          await Directory.systemTemp.createTemp('fe03_p07a_tenant_b_');
      final dbB = await databaseFactory.openDatabase(
        '${tenantBDirectory.path}${Platform.pathSeparator}tenant_b.db',
      );
      await _createSchema(dbB);
      await _activateV2(dbB, cursor: '40');
      await _insertCustomer(dbB, id: 'customer-b', name: 'Tenant B local');

      var cancelled = false;
      final requestStarted = Completer<void>();
      final finishResponse = Completer<http.Response>();
      final engine = SyncEngine(
        apiClient: _api((request) {
          requestStarted.complete();
          return finishResponse.future;
        }),
      );
      final pull = engine.pullIncrementalChanges(
        lease: _lease(db, isCancelled: () => cancelled),
      );
      await requestStarted.future;

      // Models logout plus a new authenticated organization/session becoming
      // current before the old bound response is released.
      cancelled = true;
      finishResponse.complete(http.Response(
        jsonEncode({
          'nextCursor': '2',
          'changes': [
            _updateChange(_customerRecord('customer-a', 'Late remote')),
          ],
        }),
        200,
      ));

      final summary = await pull;
      expect(summary.totalChanges, 0);
      expect(await _customerName(db, 'customer-a'), 'Tenant A local');
      expect(await _metadata(db, 'last_cursor'), '1');
      expect(await _outboxStatus(db, 'customer-a-op'), 'PENDING');
      expect(await _customerName(dbB, 'customer-b'), 'Tenant B local');
      expect(await _customerName(dbB, 'customer-a'), isNull);
      expect(await _metadata(dbB, 'last_cursor'), '40');
      await dbB.close();
      tenantBDirectory.deleteSync(recursive: true);
    });
  });
}

Matcher get _pendingMutationException => isA<SyncProjectionException>().having(
      (error) => error.code,
      'code',
      'SYNC_LOCAL_MUTATION_PENDING',
    );

ApiClient _api(Future<http.Response> Function(http.Request request) handler) {
  return ApiClient(
    baseUrl: 'http://test.api',
    client: _HttpClient(handler),
  );
}

SyncLease _lease(Database db, {bool Function()? isCancelled}) {
  return SyncLease(
    db: db,
    credential: BoundCredential.explicit('test-token'),
    isCancelled: isCancelled ?? () => false,
  );
}

Future<void> _createSchema(Database db) async {
  await db.execute('''
    CREATE TABLE outbox (
      operation_id TEXT PRIMARY KEY,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      operation_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      last_attempt_at TEXT,
      next_retry_at TEXT,
      last_error TEXT,
      status TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE customers (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      document TEXT,
      email TEXT,
      phone TEXT,
      address TEXT,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE equipments (
      id TEXT PRIMARY KEY,
      customer_id TEXT,
      organization_id TEXT,
      owner_type TEXT NOT NULL,
      organization_purpose TEXT,
      type TEXT NOT NULL,
      brand TEXT NOT NULL,
      model TEXT NOT NULL,
      serial_number TEXT,
      notes TEXT,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE service_orders (
      id TEXT PRIMARY KEY,
      friendly_id INTEGER,
      organization_id TEXT,
      customer_id TEXT,
      equipment_id TEXT NOT NULL,
      technician_id TEXT,
      status TEXT NOT NULL,
      problem_description TEXT NOT NULL,
      diagnosis TEXT,
      solution TEXT,
      total_amount_minor INTEGER NOT NULL,
      projection_revision TEXT,
      projection_fingerprint TEXT,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE service_order_items (
      id TEXT PRIMARY KEY,
      service_order_id TEXT NOT NULL,
      part_id TEXT,
      description TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      unit_price_minor INTEGER NOT NULL,
      total_price_minor INTEGER NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE payments (
      id TEXT PRIMARY KEY,
      service_order_id TEXT NOT NULL,
      customer_id TEXT NOT NULL,
      amount_minor INTEGER NOT NULL,
      method TEXT NOT NULL,
      status TEXT NOT NULL,
      notes TEXT,
      paid_at TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  ''');
  await db.execute('''
    CREATE TABLE sync_metadata (
      key TEXT PRIMARY KEY,
      value TEXT
    )
  ''');
}

Future<void> _activateV2(Database db, {required String cursor}) async {
  for (final entry in {
    'sync_contract_version': '2',
    'sync_bootstrap_proof': 'test-proof',
    'last_cursor': cursor,
  }.entries) {
    await db.insert(
      'sync_metadata',
      {'key': entry.key, 'value': entry.value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

Future<void> _insertOutbox(
  Database db, {
  required String operationId,
  required String entityType,
  required String entityId,
  String operationType = 'UPDATE',
  Map<String, dynamic> payload = const {},
  String status = 'PENDING',
}) {
  return db.insert('outbox', {
    'operation_id': operationId,
    'entity_type': entityType,
    'entity_id': entityId,
    'operation_type': operationType,
    'payload': jsonEncode(payload),
    'created_at': '2026-09-23T12:00:00.000Z',
    'attempt_count': 0,
    'status': status,
  });
}

Future<void> _insertCustomer(
  Database db, {
  required String id,
  required String name,
}) {
  return db.insert('customers', {
    'id': id,
    'name': name,
    'updated_at': '2026-09-23T12:00:00.000Z',
  });
}

Future<void> _insertEquipment(
  Database db, {
  required String id,
  required String model,
}) {
  return db.insert('equipments', {
    'id': id,
    'customer_id': 'customer-1',
    'organization_id': null,
    'owner_type': 'CUSTOMER',
    'organization_purpose': null,
    'type': 'Notebook',
    'brand': 'Brand',
    'model': model,
    'updated_at': '2026-09-23T12:00:00.000Z',
  });
}

Future<void> _insertServiceOrder(
  Database db, {
  required String id,
  required String diagnosis,
}) {
  return db.insert('service_orders', {
    'id': id,
    'friendly_id': 1,
    'organization_id': 'organization-1',
    'customer_id': 'customer-1',
    'equipment_id': 'equipment-1',
    'technician_id': null,
    'status': 'DIAGNOSTICO',
    'problem_description': 'Problem',
    'diagnosis': diagnosis,
    'solution': null,
    'total_amount_minor': 100,
    'projection_revision': '1',
    'projection_fingerprint': 'local',
    'updated_at': '2026-09-23T12:00:00.000Z',
  });
}

Future<void> _insertServiceOrderItem(
  Database db, {
  required String id,
  required String serviceOrderId,
  required String description,
}) {
  return db.insert('service_order_items', {
    'id': id,
    'service_order_id': serviceOrderId,
    'part_id': null,
    'description': description,
    'quantity': 1,
    'unit_price_minor': 100,
    'total_price_minor': 100,
    'updated_at': '2026-09-23T12:00:00.000Z',
  });
}

Map<String, dynamic> _customerRecord(String id, String name) => {
      'entityType': 'CUSTOMER',
      'entityId': id,
      'data': {
        'contractVersion': 2,
        'projectionRevision': '2',
        'id': id,
        'name': name,
        'document': null,
        'email': null,
        'phone': null,
        'address': null,
        'updatedAt': '2026-09-23T13:00:00.000Z',
      },
    };

Map<String, dynamic> _equipmentRecord(
  String id, {
  required String model,
}) =>
    {
      'entityType': 'EQUIPMENT',
      'entityId': id,
      'data': {
        'contractVersion': 2,
        'projectionRevision': '2',
        'id': id,
        'customerId': 'customer-1',
        'organizationId': null,
        'ownerType': 'CUSTOMER',
        'organizationPurpose': null,
        'type': 'Notebook',
        'brand': 'Brand',
        'model': model,
        'serialNumber': null,
        'notes': null,
        'updatedAt': '2026-09-23T13:00:00.000Z',
      },
    };

Map<String, dynamic> _serviceOrderRecord(
  String id, {
  required String diagnosis,
}) =>
    {
      'entityType': 'SERVICE_ORDER',
      'entityId': id,
      'data': {
        'contractVersion': 2,
        'projectionRevision': '2',
        'id': id,
        'friendlyId': 1,
        'organizationId': 'organization-1',
        'customerId': 'customer-1',
        'equipmentId': 'equipment-1',
        'technicianId': null,
        'status': 'DIAGNOSTICO',
        'problemDescription': 'Problem',
        'diagnosis': diagnosis,
        'solution': null,
        'totalAmountMinor': 100,
        'items': [
          {
            'id': 'item-remote',
            'serviceOrderId': id,
            'partId': null,
            'description': 'Remote item',
            'quantity': 1,
            'unitPriceMinor': 100,
            'totalPriceMinor': 100,
            'createdAt': '2026-09-23T13:00:00.000Z',
          },
        ],
        'updatedAt': '2026-09-23T13:00:00.000Z',
      },
    };

Map<String, dynamic> _updateChange(Map<String, dynamic> record) => {
      ...record,
      'operationType': 'UPDATE',
    };

Future<String?> _customerName(Database db, String id) async {
  final rows = await db.query(
    'customers',
    columns: ['name'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty ? null : rows.single['name'] as String;
}

Future<String?> _equipmentModel(Database db, String id) async {
  final rows = await db.query(
    'equipments',
    columns: ['model'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty ? null : rows.single['model'] as String;
}

Future<String?> _orderDiagnosis(Database db, String id) async {
  final rows = await db.query(
    'service_orders',
    columns: ['diagnosis'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty ? null : rows.single['diagnosis'] as String?;
}

Future<List<String>> _orderItemDescriptions(
  Database db,
  String serviceOrderId,
) async {
  final rows = await db.query(
    'service_order_items',
    columns: ['description'],
    where: 'service_order_id = ?',
    whereArgs: [serviceOrderId],
    orderBy: 'id',
  );
  return rows.map((row) => row['description'] as String).toList();
}

Future<String?> _outboxStatus(Database db, String operationId) async {
  final rows = await db.query(
    'outbox',
    columns: ['status'],
    where: 'operation_id = ?',
    whereArgs: [operationId],
  );
  return rows.isEmpty ? null : rows.single['status'] as String;
}

Future<String?> _metadata(Database db, String key) async {
  final rows = await db.query(
    'sync_metadata',
    columns: ['value'],
    where: 'key = ?',
    whereArgs: [key],
  );
  return rows.isEmpty ? null : rows.single['value'] as String?;
}
