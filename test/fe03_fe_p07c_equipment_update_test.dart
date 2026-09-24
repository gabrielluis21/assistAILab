import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/network/api_client.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
import 'package:assistailab/core/sync/sync_providers.dart';
import 'package:assistailab/core/sync/sync_projection_applier.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/customers/customer_entity.dart';
import 'package:assistailab/features/customers/customers_provider.dart';
import 'package:assistailab/features/equipment/equipment_entity.dart';
import 'package:assistailab/features/equipment/equipment_repository.dart';
import 'package:assistailab/features/equipment/equipments_page.dart';
import 'package:assistailab/features/equipment/equipments_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _scopeA =
    ProfessionalAuthScope(userId: 'user-a', organizationId: 'org-a');
const _scopeB =
    ProfessionalAuthScope(userId: 'user-b', organizationId: 'org-b');

final _controlledSessionKey =
    StateProvider<AuthenticatedSessionKey?>((ref) => null);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late BoundDatabaseHandle handle;
  late AuthenticatedSessionKey sessionKey;
  var sessionGeneration = 0;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => tempDirectory.path,
    );
  });

  setUp(() async {
    tempDirectory =
        Directory.systemTemp.createTempSync('fe03_p07c_equipment_update_');
    final generation = ++sessionGeneration;
    handle = await AuthScopedDatabaseManager.instance.openDatabaseForScope(
      _scopeA,
      sessionGeneration: generation,
    );
    sessionKey = AuthenticatedSessionKey(
      scope: _scopeA,
      sessionGeneration: generation,
    );
  });

  tearDown(() async {
    await AuthScopedDatabaseManager.instance.closeCurrentDatabase(
      sessionGeneration: ++sessionGeneration,
    );
    if (tempDirectory.existsSync()) {
      tempDirectory.deleteSync(recursive: true);
    }
  });

  group('FE03-P07-C local Equipment update', () {
    test('updates five fields and creates exact Outbox mutation atomically',
        () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      final subscription = container.listen(
        equipmentsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(equipmentsProvider.future);

      await container.read(equipmentsProvider.notifier).updateEquipment(
            id: 'equipment-1',
            type: '  Smartphone  ',
            brand: '  New Brand  ',
            model: '  New Model  ',
            serialNumber: '  IMEI-2  ',
            notes: '  Updated notes  ',
          );

      final equipment = await _findEquipment(handle.database);
      expect(equipment.type, 'Smartphone');
      expect(equipment.brand, 'New Brand');
      expect(equipment.model, 'New Model');
      expect(equipment.serialNumber, 'IMEI-2');
      expect(equipment.notes, 'Updated notes');
      expect(equipment.customerId, 'customer-1');
      expect(equipment.ownerType, EquipmentOwnerType.customer);
      expect(equipment.organizationId, isNull);
      expect(equipment.organizationPurpose, isNull);

      final outbox = (await handle.database.query('outbox')).single;
      expect(outbox['entity_type'], 'EQUIPMENT');
      expect(outbox['entity_id'], 'equipment-1');
      expect(outbox['operation_type'], 'UPDATE');
      expect(outbox['status'], 'PENDING');
      expect(outbox['operation_id'], isA<String>());
      expect((outbox['operation_id'] as String).isNotEmpty, isTrue);
      expect(jsonDecode(outbox['payload'] as String), {
        'customerId': 'customer-1',
        'type': 'Smartphone',
        'brand': 'New Brand',
        'model': 'New Model',
        'serialNumber': 'IMEI-2',
        'notes': 'Updated notes',
      });
      expect(
          (jsonDecode(outbox['payload'] as String) as Map),
          isNot(
            contains('ownerType'),
          ));

      final published = container.read(equipmentsProvider).requireValue.single;
      expect(published.model, 'New Model');
    });

    test('clears optional fields and enforces Backend field bounds', () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);

      await container.read(equipmentsProvider.notifier).updateEquipment(
            id: 'equipment-1',
            type: 'Notebook',
            brand: 'Brand',
            model: 'Model',
            serialNumber: '   ',
            notes: '',
          );

      final equipment = await _findEquipment(handle.database);
      expect(equipment.serialNumber, isNull);
      expect(equipment.notes, isNull);
      final payload = jsonDecode(
        (await handle.database.query('outbox')).single['payload'] as String,
      ) as Map<String, dynamic>;
      expect(payload['serialNumber'], isNull);
      expect(payload['notes'], isNull);

      await handle.database.delete('outbox');
      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-1',
              type: ' ',
              brand: 'Brand',
              model: 'Model',
            ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-1',
              type: 'Notebook',
              brand: 'x' * 501,
              model: 'Model',
            ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-1',
              type: 'Notebook',
              brand: 'Brand',
              model: 'Model',
              notes: 'x' * 10001,
            ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await handle.database.query('outbox'), isEmpty);
      expect((await _findEquipment(handle.database)).model, 'Model');
    });

    test('Outbox failure rolls back Equipment and requests no Sync', () async {
      await _seedEquipment(handle.database);
      final container = _container(
        sessionKey,
        outboxDao: _ThrowingOutboxDao(),
        online: true,
        failIfSyncRequested: true,
      );
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);

      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-1',
              type: 'Notebook',
              brand: 'Brand',
              model: 'Must roll back',
            ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Simulated Outbox failure.',
          ),
        ),
      );

      expect((await _findEquipment(handle.database)).model, 'Original Model');
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('repository failure creates no partial Outbox mutation', () async {
      await _seedEquipment(handle.database);
      final container = _container(
        sessionKey,
        repository: _ThrowingEquipmentRepository(
          EquipmentLocalDataSource(),
        ),
      );
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);

      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-1',
              type: 'Notebook',
              brand: 'Brand',
              model: 'Must not persist',
            ),
        throwsA(isA<StateError>()),
      );

      expect((await _findEquipment(handle.database)).model, 'Original Model');
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('unknown Equipment is rejected before SQLite, Outbox and Sync',
        () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);

      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-from-another-tenant',
              type: 'Notebook',
              brand: 'Brand',
              model: 'Cross tenant attempt',
            ),
        throwsA(isA<StateError>()),
      );

      expect((await _findEquipment(handle.database)).model, 'Original Model');
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('ORGANIZATION-owned Equipment cannot use generic update', () async {
      await _seedEquipment(
        handle.database,
        ownerType: EquipmentOwnerType.organization,
        customerId: null,
        organizationId: 'org-a',
        organizationPurpose: EquipmentOrganizationPurpose.resale,
      );
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);

      await expectLater(
        container.read(equipmentsProvider.notifier).updateEquipment(
              id: 'equipment-1',
              type: 'Notebook',
              brand: 'Brand',
              model: 'Forbidden generic update',
            ),
        throwsA(isA<StateError>()),
      );

      final equipment = await _findEquipment(handle.database);
      expect(equipment.model, 'Original Model');
      expect(equipment.ownerType, EquipmentOwnerType.organization);
      expect(equipment.organizationId, 'org-a');
      expect(
          equipment.organizationPurpose, EquipmentOrganizationPurpose.resale);
      expect(await handle.database.query('outbox'), isEmpty);
    });
  });

  group('FE03-P07-C P07-A projection compatibility', () {
    test('PENDING and PROCESSING protect update/delete; SYNCED converges',
        () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);
      await container.read(equipmentsProvider.notifier).updateEquipment(
            id: 'equipment-1',
            type: 'Notebook',
            brand: 'Brand',
            model: 'Local update',
          );

      final operationId =
          (await handle.database.query('outbox')).single['operation_id'];
      await expectLater(
        SyncProjectionApplier.applyChange(
          handle.database,
          _remoteEquipmentChange('Remote stale'),
        ),
        throwsA(_pendingMutationException),
      );
      await expectLater(
        SyncProjectionApplier.applyChange(
          handle.database,
          _remoteEquipmentDelete(),
        ),
        throwsA(_pendingMutationException),
      );
      expect((await _findEquipment(handle.database)).model, 'Local update');

      await handle.database.update(
        'outbox',
        {'status': 'PROCESSING'},
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      await expectLater(
        SyncProjectionApplier.applyChange(
          handle.database,
          _remoteEquipmentChange('Remote still stale'),
        ),
        throwsA(_pendingMutationException),
      );
      expect((await _findEquipment(handle.database)).model, 'Local update');

      await handle.database.update(
        'outbox',
        {'status': 'SYNCED'},
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      await SyncProjectionApplier.applyChange(
        handle.database,
        _remoteEquipmentChange('Server confirmed'),
      );
      expect((await _findEquipment(handle.database)).model, 'Server confirmed');
    });

    test('Equipment without pending mutation accepts remote projection',
        () async {
      await _seedEquipment(handle.database);

      await SyncProjectionApplier.applyChange(
        handle.database,
        _remoteEquipmentChange('Remote current'),
      );

      expect((await _findEquipment(handle.database)).model, 'Remote current');
    });

    test('Sync transports UPDATE, confirms Outbox and releases convergence',
        () async {
      await _seedEquipment(handle.database);
      await _activateSyncV2(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(equipmentsProvider.future);
      await container.read(equipmentsProvider.notifier).updateEquipment(
            id: 'equipment-1',
            type: 'Tablet',
            brand: 'Transported Brand',
            model: 'Transported Model',
            serialNumber: 'SERIAL-2',
            notes: 'Transported notes',
          );
      final operationId =
          (await handle.database.query('outbox')).single['operation_id'];
      Map<String, dynamic>? requestBody;
      final engine = SyncEngine(
        apiClient: ApiClient(
          baseUrl: 'http://test.api',
          client: _HttpClient((request) async {
            expect(request.url.path, '/sync/push');
            requestBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'results': [
                  {'operationId': operationId, 'status': 'SYNCED'},
                ],
              }),
              200,
            );
          }),
        ),
        outboxDao: OutboxDao(),
      );

      final summary = await engine.pushPendingOutbox(
        lease: SyncLease(
          db: handle.database,
          credential: BoundCredential.explicit('test-token'),
          isCancelled: () => false,
        ),
      );

      expect(summary.syncedCount, 1);
      final entry = (requestBody!['entries'] as List).single as Map;
      expect(entry['entityType'], 'EQUIPMENT');
      expect(entry['entityId'], 'equipment-1');
      expect(entry['operationType'], 'UPDATE');
      expect(entry['payload'], {
        'customerId': 'customer-1',
        'type': 'Tablet',
        'brand': 'Transported Brand',
        'model': 'Transported Model',
        'serialNumber': 'SERIAL-2',
        'notes': 'Transported notes',
      });
      expect(
          (await handle.database.query('outbox')).single['status'], 'SYNCED');

      await SyncProjectionApplier.applyChange(
        handle.database,
        _remoteEquipmentChange('Server converged'),
      );
      expect((await _findEquipment(handle.database)).model, 'Server converged');
    });
  });

  group('FE03-P07-C session and tenant isolation', () {
    test('logout during update cannot publish a stale result', () async {
      await _seedEquipment(handle.database);
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = _controlledContainer(
        sessionKey,
        repository: _BlockingEquipmentRepository(
          EquipmentLocalDataSource(),
          entered,
          release,
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        equipmentsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(equipmentsProvider.future);

      final update =
          container.read(equipmentsProvider.notifier).updateEquipment(
                id: 'equipment-1',
                type: 'Notebook',
                brand: 'Brand',
                model: 'Committed only to A',
              );
      await entered.future;
      container.read(_controlledSessionKey.notifier).state = null;
      release.complete();

      await expectLater(update, throwsA(anything));
      expect(
          (await _findEquipment(handle.database)).model, 'Committed only to A');
      expect((await handle.database.query('outbox')).length, 1);
    });

    test('user and organization switch never writes into tenant B', () async {
      await _seedEquipment(handle.database);
      final dbA = handle.database;
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = _controlledContainer(
        sessionKey,
        repository: _BlockingEquipmentRepository(
          EquipmentLocalDataSource(),
          entered,
          release,
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        equipmentsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(equipmentsProvider.future);

      final update =
          container.read(equipmentsProvider.notifier).updateEquipment(
                id: 'equipment-1',
                type: 'Notebook',
                brand: 'Brand',
                model: 'Tenant A only',
              );
      await entered.future;
      final keyB = AuthenticatedSessionKey(
        scope: _scopeB,
        sessionGeneration: sessionGeneration + 1,
      );
      container.read(_controlledSessionKey.notifier).state = keyB;
      release.complete();
      await expectLater(update, throwsA(anything));

      expect(
          (await EquipmentLocalDataSource().findById(
            'equipment-1',
            executor: dbA,
          ))!
              .model,
          'Tenant A only');
      expect((await dbA.query('outbox')).length, 1);

      handle = await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        _scopeB,
        sessionGeneration: ++sessionGeneration,
      );
      expect(await handle.database.query('equipments'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });
  });

  testWidgets('Equipment UI edits only the five supported fields',
      (tester) async {
    final notifier = _RecordingEquipmentsNotifier(_customerOwnedEquipment());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          equipmentsProvider.overrideWith(() => notifier),
          customersProvider.overrideWith(_EmptyCustomersNotifier.new),
        ],
        child: const MaterialApp(home: EquipmentsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();

    expect(find.text('Editar Equipamento'), findsOneWidget);
    expect(find.text('Cliente *'), findsNothing);
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(5));
    await tester.enterText(fields.at(0), 'Tablet');
    await tester.enterText(fields.at(1), 'Edited Brand');
    await tester.enterText(fields.at(2), 'Edited Model');
    await tester.enterText(fields.at(3), 'IMEI-EDITED');
    await tester.enterText(fields.at(4), 'Edited notes');
    await tester.tap(find.text('Salvar').last);
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 1);
    expect(notifier.updatedId, 'equipment-1');
    expect(notifier.updatedType, 'Tablet');
    expect(notifier.updatedBrand, 'Edited Brand');
    expect(notifier.updatedModel, 'Edited Model');
    expect(notifier.updatedSerialNumber, 'IMEI-EDITED');
    expect(notifier.updatedNotes, 'Edited notes');
  });

  testWidgets('ORGANIZATION-owned Equipment has no generic edit action',
      (tester) async {
    final notifier = _RecordingEquipmentsNotifier(
      _organizationOwnedEquipment(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          equipmentsProvider.overrideWith(() => notifier),
          customersProvider.overrideWith(_EmptyCustomersNotifier.new),
        ],
        child: const MaterialApp(home: EquipmentsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.edit), findsNothing);
    expect(find.text('Editar Equipamento'), findsNothing);
  });
}

ProviderContainer _container(
  AuthenticatedSessionKey key, {
  EquipmentRepository? repository,
  OutboxDao? outboxDao,
  bool online = false,
  bool failIfSyncRequested = false,
}) {
  return ProviderContainer(
    overrides: [
      authenticatedSessionKeyProvider.overrideWithValue(key),
      isOnlineSessionProvider.overrideWithValue(online),
      if (repository != null)
        equipmentRepositoryProvider.overrideWithValue(repository),
      if (outboxDao != null) outboxDaoProvider.overrideWithValue(outboxDao),
      if (failIfSyncRequested)
        syncSchedulerProvider.overrideWith(
          (ref) => throw StateError('Sync requested before commit.'),
        ),
    ],
  );
}

ProviderContainer _controlledContainer(
  AuthenticatedSessionKey key, {
  required EquipmentRepository repository,
}) {
  return ProviderContainer(
    overrides: [
      _controlledSessionKey.overrideWith((ref) => key),
      authenticatedSessionKeyProvider.overrideWith(
        (ref) => ref.watch(_controlledSessionKey),
      ),
      isOnlineSessionProvider.overrideWithValue(false),
      equipmentRepositoryProvider.overrideWithValue(repository),
    ],
  );
}

Future<void> _seedEquipment(
  Database db, {
  EquipmentOwnerType ownerType = EquipmentOwnerType.customer,
  String? customerId = 'customer-1',
  String? organizationId,
  EquipmentOrganizationPurpose? organizationPurpose,
}) async {
  if (customerId != null) {
    await db.insert('customers', {
      'id': customerId,
      'name': 'Customer',
      'updated_at': '2026-09-24T10:00:00.000Z',
    });
  }
  await EquipmentLocalDataSource().upsert(
    EquipmentEntity(
      id: 'equipment-1',
      customerId: customerId,
      organizationId: organizationId,
      ownerType: ownerType,
      organizationPurpose: organizationPurpose,
      type: 'Notebook',
      brand: 'Original Brand',
      model: 'Original Model',
      serialNumber: 'SERIAL-1',
      notes: 'Original notes',
      updatedAt: '2026-09-24T10:00:00.000Z',
    ),
    executor: db,
  );
}

Future<EquipmentEntity> _findEquipment(Database db) async {
  return (await EquipmentLocalDataSource().findById(
    'equipment-1',
    executor: db,
  ))!;
}

Map<String, dynamic> _remoteEquipmentChange(String model) => {
      'entityType': 'EQUIPMENT',
      'entityId': 'equipment-1',
      'operationType': 'UPDATE',
      'data': {
        'contractVersion': 2,
        'projectionRevision': '2',
        'id': 'equipment-1',
        'customerId': 'customer-1',
        'organizationId': null,
        'ownerType': 'CUSTOMER',
        'organizationPurpose': null,
        'type': 'Notebook',
        'brand': 'Remote Brand',
        'model': model,
        'serialNumber': null,
        'notes': null,
        'updatedAt': '2026-09-24T14:00:00.000Z',
      },
    };

Map<String, dynamic> _remoteEquipmentDelete() => {
      'entityType': 'EQUIPMENT',
      'entityId': 'equipment-1',
      'operationType': 'DELETE',
      'data': {
        'id': 'equipment-1',
        'deleted': true,
        'contractVersion': 2,
        'projectionRevision': '2',
      },
    };

Matcher get _pendingMutationException => isA<SyncProjectionException>().having(
      (error) => error.code,
      'code',
      'SYNC_LOCAL_MUTATION_PENDING',
    );

Future<void> _activateSyncV2(Database db) async {
  for (final entry in const {
    'sync_contract_version': '2',
    'sync_bootstrap_proof': 'test-proof',
    'last_cursor': '1',
  }.entries) {
    await db.insert(
      'sync_metadata',
      {'key': entry.key, 'value': entry.value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }
}

EquipmentEntity _customerOwnedEquipment() => EquipmentEntity(
      id: 'equipment-1',
      customerId: 'customer-1',
      type: 'Notebook',
      brand: 'Original Brand',
      model: 'Original Model',
      serialNumber: 'SERIAL-1',
      notes: 'Original notes',
      updatedAt: '2026-09-24T10:00:00.000Z',
    );

EquipmentEntity _organizationOwnedEquipment() => EquipmentEntity(
      id: 'equipment-1',
      organizationId: 'org-a',
      ownerType: EquipmentOwnerType.organization,
      organizationPurpose: EquipmentOrganizationPurpose.resale,
      type: 'Notebook',
      brand: 'Organization Brand',
      model: 'Organization Model',
      updatedAt: '2026-09-24T10:00:00.000Z',
    );

final class _HttpClient extends http.BaseClient {
  _HttpClient(this.handler);

  final Future<http.Response> Function(http.Request request) handler;

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

final class _ThrowingOutboxDao extends OutboxDao {
  @override
  Future<void> insert(
    OutboxItem item, {
    DatabaseExecutor? executor,
  }) {
    throw StateError('Simulated Outbox failure.');
  }
}

final class _ThrowingEquipmentRepository implements EquipmentRepository {
  _ThrowingEquipmentRepository(this.delegate);

  final EquipmentRepository delegate;

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) =>
      delegate.delete(id, executor: executor);

  @override
  Future<EquipmentEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) =>
      delegate.findById(id, executor: executor);

  @override
  Future<List<EquipmentEntity>> listAll({DatabaseExecutor? executor}) =>
      delegate.listAll(executor: executor);

  @override
  Future<List<EquipmentEntity>> listByCustomer(
    String customerId, {
    DatabaseExecutor? executor,
  }) =>
      delegate.listByCustomer(customerId, executor: executor);

  @override
  Future<void> upsert(
    EquipmentEntity equipment, {
    DatabaseExecutor? executor,
  }) {
    throw StateError('Simulated repository failure.');
  }
}

final class _BlockingEquipmentRepository implements EquipmentRepository {
  _BlockingEquipmentRepository(this.delegate, this.entered, this.release);

  final EquipmentRepository delegate;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) =>
      delegate.delete(id, executor: executor);

  @override
  Future<EquipmentEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) =>
      delegate.findById(id, executor: executor);

  @override
  Future<List<EquipmentEntity>> listAll({DatabaseExecutor? executor}) =>
      delegate.listAll(executor: executor);

  @override
  Future<List<EquipmentEntity>> listByCustomer(
    String customerId, {
    DatabaseExecutor? executor,
  }) =>
      delegate.listByCustomer(customerId, executor: executor);

  @override
  Future<void> upsert(
    EquipmentEntity equipment, {
    DatabaseExecutor? executor,
  }) async {
    await delegate.upsert(equipment, executor: executor);
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

final class _RecordingEquipmentsNotifier extends EquipmentsNotifier {
  _RecordingEquipmentsNotifier(this.equipment);

  final EquipmentEntity equipment;
  int updateCalls = 0;
  String? updatedId;
  String? updatedType;
  String? updatedBrand;
  String? updatedModel;
  String? updatedSerialNumber;
  String? updatedNotes;

  @override
  Future<List<EquipmentEntity>> build() async => [equipment];

  @override
  Future<void> updateEquipment({
    required String id,
    required String type,
    required String brand,
    required String model,
    String? serialNumber,
    String? notes,
  }) async {
    updateCalls++;
    updatedId = id;
    updatedType = type;
    updatedBrand = brand;
    updatedModel = model;
    updatedSerialNumber = serialNumber;
    updatedNotes = notes;
  }
}

final class _EmptyCustomersNotifier extends CustomersNotifier {
  @override
  Future<List<CustomerEntity>> build() async => const [];
}
