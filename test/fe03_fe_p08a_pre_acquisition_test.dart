import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:assistailab/core/sync/sync_providers.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/equipment/equipment_entity.dart';
import 'package:assistailab/features/equipment/equipment_repository.dart';
import 'package:assistailab/features/equipment/equipments_provider.dart';
import 'package:assistailab/features/equipment/pre_acquisition_entity.dart';
import 'package:assistailab/features/equipment/pre_acquisition_repository.dart';
import 'package:assistailab/features/equipment/pre_acquisitions_page.dart';
import 'package:assistailab/features/equipment/pre_acquisitions_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
        Directory.systemTemp.createTempSync('fe03_p08a_pre_acquisition_');
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

  group('FE03-P08-A SQLite schema extension', () {
    test('migration creates the complete constrained table idempotently',
        () async {
      expect(SqliteDatabase.schemaVersion, 7);
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false),
      );
      addTearDown(db.close);

      await SqliteDatabase.ensurePreAcquisitionSchema(db);
      await SqliteDatabase.ensurePreAcquisitionSchema(db);

      final columns = await db.rawQuery('PRAGMA table_info(pre_acquisitions)');
      expect(
        columns.map((column) => column['name']).toSet(),
        {
          'id',
          'equipment_id',
          'customer_id',
          'organization_id',
          'service_order_id',
          'status',
          'offered_amount_minor',
          'notes',
          'created_at',
          'evaluation_deadline',
          'evaluated_at',
          'resolution_reason',
        },
      );
      expect(
        columns.singleWhere(
          (column) => column['name'] == 'offered_amount_minor',
        )['type'],
        'INTEGER',
      );

      await expectLater(
        db.insert('pre_acquisitions', _rawPreAcquisition(status: 'INVALID')),
        throwsA(isA<DatabaseException>()),
      );
      await expectLater(
        db.insert(
          'pre_acquisitions',
          _rawPreAcquisition(
            status: 'PENDING_EVALUATION',
            offeredAmountMinor: -1,
          ),
        ),
        throwsA(isA<DatabaseException>()),
      );
    });
  });

  group('FE03-P08-A local creation', () {
    test('derives identity and atomically creates local record plus Outbox',
        () async {
      await _seedEquipment(handle.database);
      final beforeEquipment = (await _findEquipment(handle.database)).toMap();
      final container = _container(sessionKey, failIfSyncRequested: true);
      addTearDown(container.dispose);
      final subscription = container.listen(
        preAcquisitionsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(preAcquisitionsProvider.future);

      await container
          .read(preAcquisitionsProvider.notifier)
          .createPreAcquisition(
            equipmentId: 'equipment-1',
            serviceOrderId: '  service-order-1  ',
            offeredAmountMinor: 12500,
            notes: '  Avaliar carcaça  ',
            evaluationDeadline: DateTime.utc(2026, 10, 1),
          );

      final record = (await PreAcquisitionLocalDataSource().listAll(
        executor: handle.database,
      ))
          .single;
      expect(record.equipmentId, 'equipment-1');
      expect(record.customerId, 'customer-1');
      expect(record.organizationId, 'org-a');
      expect(record.serviceOrderId, 'service-order-1');
      expect(record.status, PreAcquisitionStatus.pendingEvaluation);
      expect(record.offeredAmountMinor, 12500);
      expect(record.notes, 'Avaliar carcaça');
      expect(record.evaluationDeadline, '2026-10-01T00:00:00.000Z');
      expect(record.evaluatedAt, isNull);
      expect(record.resolutionReason, isNull);

      final outbox = (await handle.database.query('outbox')).single;
      expect(outbox['entity_type'], 'PRE_ACQUISITION');
      expect(outbox['entity_id'], record.id);
      expect(outbox['operation_type'], 'CREATE');
      expect(outbox['status'], 'REQUIRES_ATTENTION');
      expect(jsonDecode(outbox['payload'] as String), {
        'equipmentId': 'equipment-1',
        'customerId': 'customer-1',
        'organizationId': 'org-a',
        'serviceOrderId': 'service-order-1',
        'status': 'PENDING_EVALUATION',
        'offeredAmountMinor': 12500,
        'notes': 'Avaliar carcaça',
        'createdAt': record.createdAt,
        'evaluationDeadline': '2026-10-01T00:00:00.000Z',
        'evaluatedAt': null,
        'resolutionReason': null,
      });
      expect(
          await OutboxDao().getPendingEntries(
            executor: handle.database,
          ),
          isEmpty);
      expect((await _findEquipment(handle.database)).toMap(), beforeEquipment);

      final published =
          container.read(preAcquisitionsProvider).requireValue.single;
      expect(published.id, record.id);
    });

    test('nullable fields stay null and past deadline does not auto-expire',
        () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);

      await container
          .read(preAcquisitionsProvider.notifier)
          .createPreAcquisition(
            equipmentId: 'equipment-1',
            serviceOrderId: ' ',
            notes: '',
            evaluationDeadline: DateTime.utc(2020, 1, 1),
          );
      await container.read(preAcquisitionsProvider.notifier).refresh();

      final record = (await PreAcquisitionLocalDataSource().listAll(
        executor: handle.database,
      ))
          .single;
      expect(record.serviceOrderId, isNull);
      expect(record.offeredAmountMinor, isNull);
      expect(record.notes, isNull);
      expect(record.status, PreAcquisitionStatus.pendingEvaluation);
      expect(record.evaluatedAt, isNull);
      expect((await handle.database.query('outbox')).length, 1);
    });

    test('negative offered amount fails before any mutation', () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);

      await expectLater(
        container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
              equipmentId: 'equipment-1',
              offeredAmountMinor: -1,
              evaluationDeadline: DateTime.utc(2026, 10, 1),
            ),
        throwsA(isA<ArgumentError>()),
      );
      expect(await handle.database.query('pre_acquisitions'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('missing Equipment creates neither record nor Outbox', () async {
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);

      await expectLater(
        container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
              equipmentId: 'missing-equipment',
              evaluationDeadline: DateTime.utc(2026, 10, 1),
            ),
        throwsA(isA<StateError>()),
      );
      expect(await handle.database.query('pre_acquisitions'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('ORGANIZATION-owned Equipment is ineligible and remains unchanged',
        () async {
      await _seedEquipment(
        handle.database,
        ownerType: EquipmentOwnerType.organization,
        customerId: null,
        organizationId: 'org-a',
        purpose: EquipmentOrganizationPurpose.resale,
      );
      final before = (await _findEquipment(handle.database)).toMap();
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);

      await expectLater(
        container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
              equipmentId: 'equipment-1',
              evaluationDeadline: DateTime.utc(2026, 10, 1),
            ),
        throwsA(isA<StateError>()),
      );
      expect(await handle.database.query('pre_acquisitions'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
      expect((await _findEquipment(handle.database)).toMap(), before);
    });

    test('Outbox failure rolls back the local record', () async {
      await _seedEquipment(handle.database);
      final container = _container(
        sessionKey,
        outboxDao: _ThrowingOutboxDao(),
      );
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);

      await expectLater(
        container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
              equipmentId: 'equipment-1',
              evaluationDeadline: DateTime.utc(2026, 10, 1),
            ),
        throwsA(isA<StateError>()),
      );
      expect(await handle.database.query('pre_acquisitions'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('repository failure creates no partial Outbox', () async {
      await _seedEquipment(handle.database);
      final container = _container(
        sessionKey,
        repository: _ThrowingPreAcquisitionRepository(
          PreAcquisitionLocalDataSource(),
        ),
      );
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);

      await expectLater(
        container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
              equipmentId: 'equipment-1',
              evaluationDeadline: DateTime.utc(2026, 10, 1),
            ),
        throwsA(isA<StateError>()),
      );
      expect(await handle.database.query('pre_acquisitions'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });
  });

  group('FE03-P08-A local resolution', () {
    for (final status in const [
      PreAcquisitionStatus.approved,
      PreAcquisitionStatus.rejected,
      PreAcquisitionStatus.expired,
      PreAcquisitionStatus.cancelled,
    ]) {
      test('${status.wireValue} is explicit and creates UPDATE attention item',
          () async {
        await _seedEquipment(handle.database);
        final beforeEquipment = (await _findEquipment(handle.database)).toMap();
        final container = _container(sessionKey);
        addTearDown(container.dispose);
        await container.read(preAcquisitionsProvider.future);
        await container
            .read(preAcquisitionsProvider.notifier)
            .createPreAcquisition(
              equipmentId: 'equipment-1',
              offeredAmountMinor: 5000,
              evaluationDeadline: DateTime.utc(2026, 10, 1),
            );
        final id = (await PreAcquisitionLocalDataSource().listAll(
          executor: handle.database,
        ))
            .single
            .id;

        await container
            .read(preAcquisitionsProvider.notifier)
            .resolvePreAcquisition(
              id: id,
              status: status,
              resolutionReason: '  decisão local  ',
            );

        final resolved = (await PreAcquisitionLocalDataSource().findById(
          id,
          executor: handle.database,
        ))!;
        expect(resolved.status, status);
        expect(resolved.evaluatedAt, isNotNull);
        expect(resolved.resolutionReason, 'decisão local');
        final outbox = await handle.database.query(
          'outbox',
          orderBy: 'created_at ASC',
        );
        expect(outbox.length, 2);
        expect(outbox.last['operation_type'], 'UPDATE');
        expect(outbox.last['status'], 'REQUIRES_ATTENTION');
        expect(
          (jsonDecode(outbox.last['payload'] as String) as Map)['status'],
          status.wireValue,
        );
        expect(
            await OutboxDao().getPendingEntries(
              executor: handle.database,
            ),
            isEmpty);
        expect(
          (await _findEquipment(handle.database)).toMap(),
          beforeEquipment,
        );
      });
    }

    test('resolved record cannot transition again', () async {
      await _seedEquipment(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(preAcquisitionsProvider.future);
      await container
          .read(preAcquisitionsProvider.notifier)
          .createPreAcquisition(
            equipmentId: 'equipment-1',
            evaluationDeadline: DateTime.utc(2026, 10, 1),
          );
      final id = (await PreAcquisitionLocalDataSource().listAll(
        executor: handle.database,
      ))
          .single
          .id;
      await container
          .read(preAcquisitionsProvider.notifier)
          .resolvePreAcquisition(
            id: id,
            status: PreAcquisitionStatus.approved,
          );

      await expectLater(
        container.read(preAcquisitionsProvider.notifier).resolvePreAcquisition(
              id: id,
              status: PreAcquisitionStatus.cancelled,
            ),
        throwsA(isA<StateError>()),
      );
      expect((await handle.database.query('outbox')).length, 2);
      expect(
        (await PreAcquisitionLocalDataSource().findById(
          id,
          executor: handle.database,
        ))!
            .status,
        PreAcquisitionStatus.approved,
      );
    });

    test('Outbox failure rolls back resolution', () async {
      await _seedEquipment(handle.database);
      final normal = _container(sessionKey);
      await normal.read(preAcquisitionsProvider.future);
      await normal.read(preAcquisitionsProvider.notifier).createPreAcquisition(
            equipmentId: 'equipment-1',
            evaluationDeadline: DateTime.utc(2026, 10, 1),
          );
      final id = (await PreAcquisitionLocalDataSource().listAll(
        executor: handle.database,
      ))
          .single
          .id;
      normal.dispose();
      final failing = _container(
        sessionKey,
        outboxDao: _ThrowingOutboxDao(),
      );
      addTearDown(failing.dispose);
      await failing.read(preAcquisitionsProvider.future);

      await expectLater(
        failing.read(preAcquisitionsProvider.notifier).resolvePreAcquisition(
              id: id,
              status: PreAcquisitionStatus.approved,
            ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await PreAcquisitionLocalDataSource().findById(
          id,
          executor: handle.database,
        ))!
            .status,
        PreAcquisitionStatus.pendingEvaluation,
      );
      expect((await handle.database.query('outbox')).length, 1);
    });
  });

  group('FE03-P08-A session isolation', () {
    test('logout during create cannot publish into a stale session', () async {
      await _seedEquipment(handle.database);
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = _controlledContainer(
        sessionKey,
        repository: _BlockingPreAcquisitionRepository(
          PreAcquisitionLocalDataSource(),
          entered,
          release,
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        preAcquisitionsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(preAcquisitionsProvider.future);

      final create =
          container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
                equipmentId: 'equipment-1',
                evaluationDeadline: DateTime.utc(2026, 10, 1),
              );
      await entered.future;
      container.read(_controlledSessionKey.notifier).state = null;
      release.complete();

      await expectLater(create, throwsA(isA<StateError>()));
      expect((await handle.database.query('pre_acquisitions')).length, 1);
      expect((await handle.database.query('outbox')).length, 1);
    });

    test('organization switch never writes PreAcquisition into tenant B',
        () async {
      await _seedEquipment(handle.database);
      final dbA = handle.database;
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = _controlledContainer(
        sessionKey,
        repository: _BlockingPreAcquisitionRepository(
          PreAcquisitionLocalDataSource(),
          entered,
          release,
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        preAcquisitionsProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(preAcquisitionsProvider.future);

      final create =
          container.read(preAcquisitionsProvider.notifier).createPreAcquisition(
                equipmentId: 'equipment-1',
                evaluationDeadline: DateTime.utc(2026, 10, 1),
              );
      await entered.future;
      container.read(_controlledSessionKey.notifier).state =
          AuthenticatedSessionKey(
        scope: _scopeB,
        sessionGeneration: sessionGeneration + 1,
      );
      release.complete();
      await expectLater(create, throwsA(isA<StateError>()));
      expect((await dbA.query('pre_acquisitions')).length, 1);

      handle = await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        _scopeB,
        sessionGeneration: ++sessionGeneration,
      );
      expect(await handle.database.query('pre_acquisitions'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });
  });

  testWidgets('UI offers only CUSTOMER-owned Equipment and local fields',
      (tester) async {
    final notifier = _RecordingPreAcquisitionsNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preAcquisitionsProvider.overrideWith(() => notifier),
          equipmentsProvider.overrideWith(_RecordingEquipmentsNotifier.new),
        ],
        child: const MaterialApp(home: PreAcquisitionsPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Nova pré-aquisição'));
    await tester.pumpAndSettle();
    expect(find.text('Customer Brand Customer Model'), findsOneWidget);
    expect(find.text('Organization Brand Organization Model'), findsNothing);
    expect(find.text('Owner Type'), findsNothing);
    expect(find.text('Organization'), findsNothing);

    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(0), 'service-order-1');
    await tester.enterText(fields.at(1), '15000');
    await tester.enterText(fields.at(2), 'Avaliação local');
    await tester.tap(find.text('Salvar localmente'));
    await tester.pumpAndSettle();

    expect(notifier.createCalls, 1);
    expect(notifier.equipmentId, 'equipment-customer');
    expect(notifier.serviceOrderId, 'service-order-1');
    expect(notifier.offeredAmountMinor, 15000);
    expect(notifier.notes, 'Avaliação local');
  });
}

ProviderContainer _container(
  AuthenticatedSessionKey key, {
  PreAcquisitionRepository? repository,
  OutboxDao? outboxDao,
  bool failIfSyncRequested = false,
}) {
  return ProviderContainer(
    overrides: [
      authenticatedSessionKeyProvider.overrideWithValue(key),
      isOnlineSessionProvider.overrideWithValue(true),
      if (repository != null)
        preAcquisitionRepositoryProvider.overrideWithValue(repository),
      if (outboxDao != null) outboxDaoProvider.overrideWithValue(outboxDao),
      if (failIfSyncRequested)
        syncSchedulerProvider.overrideWith(
          (ref) => throw StateError('Remote Sync must not be requested.'),
        ),
    ],
  );
}

ProviderContainer _controlledContainer(
  AuthenticatedSessionKey key, {
  required PreAcquisitionRepository repository,
}) {
  return ProviderContainer(
    overrides: [
      _controlledSessionKey.overrideWith((ref) => key),
      authenticatedSessionKeyProvider.overrideWith(
        (ref) => ref.watch(_controlledSessionKey),
      ),
      isOnlineSessionProvider.overrideWithValue(true),
      preAcquisitionRepositoryProvider.overrideWithValue(repository),
    ],
  );
}

Future<void> _seedEquipment(
  Database db, {
  EquipmentOwnerType ownerType = EquipmentOwnerType.customer,
  String? customerId = 'customer-1',
  String? organizationId,
  EquipmentOrganizationPurpose? purpose,
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
      organizationPurpose: purpose,
      type: 'Notebook',
      brand: 'Brand',
      model: 'Model',
      serialNumber: 'SERIAL-1',
      notes: 'Unchanged',
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

Map<String, Object?> _rawPreAcquisition({
  required String status,
  int? offeredAmountMinor,
}) {
  return {
    'id': 'pre-1',
    'equipment_id': 'equipment-1',
    'customer_id': 'customer-1',
    'organization_id': 'org-a',
    'service_order_id': null,
    'status': status,
    'offered_amount_minor': offeredAmountMinor,
    'notes': null,
    'created_at': '2026-09-24T10:00:00.000Z',
    'evaluation_deadline': '2026-10-01T00:00:00.000Z',
    'evaluated_at': null,
    'resolution_reason': null,
  };
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

final class _ThrowingPreAcquisitionRepository
    implements PreAcquisitionRepository {
  _ThrowingPreAcquisitionRepository(this.delegate);

  final PreAcquisitionRepository delegate;

  @override
  Future<PreAcquisitionEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) =>
      delegate.findById(id, executor: executor);

  @override
  Future<void> insert(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  }) {
    throw StateError('Simulated repository failure.');
  }

  @override
  Future<List<PreAcquisitionEntity>> listAll({
    DatabaseExecutor? executor,
  }) =>
      delegate.listAll(executor: executor);

  @override
  Future<void> update(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  }) =>
      delegate.update(preAcquisition, executor: executor);
}

final class _BlockingPreAcquisitionRepository
    implements PreAcquisitionRepository {
  _BlockingPreAcquisitionRepository(
    this.delegate,
    this.entered,
    this.release,
  );

  final PreAcquisitionRepository delegate;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<PreAcquisitionEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) =>
      delegate.findById(id, executor: executor);

  @override
  Future<void> insert(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  }) async {
    await delegate.insert(preAcquisition, executor: executor);
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }

  @override
  Future<List<PreAcquisitionEntity>> listAll({
    DatabaseExecutor? executor,
  }) =>
      delegate.listAll(executor: executor);

  @override
  Future<void> update(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  }) =>
      delegate.update(preAcquisition, executor: executor);
}

final class _RecordingPreAcquisitionsNotifier extends PreAcquisitionsNotifier {
  int createCalls = 0;
  String? equipmentId;
  String? serviceOrderId;
  int? offeredAmountMinor;
  String? notes;
  DateTime? evaluationDeadline;

  @override
  Future<List<PreAcquisitionEntity>> build() async => const [];

  @override
  Future<void> createPreAcquisition({
    required String equipmentId,
    String? serviceOrderId,
    int? offeredAmountMinor,
    String? notes,
    required DateTime evaluationDeadline,
  }) async {
    createCalls++;
    this.equipmentId = equipmentId;
    this.serviceOrderId = serviceOrderId;
    this.offeredAmountMinor = offeredAmountMinor;
    this.notes = notes;
    this.evaluationDeadline = evaluationDeadline;
  }
}

final class _RecordingEquipmentsNotifier extends EquipmentsNotifier {
  @override
  Future<List<EquipmentEntity>> build() async => [
        EquipmentEntity(
          id: 'equipment-customer',
          customerId: 'customer-1',
          type: 'Notebook',
          brand: 'Customer Brand',
          model: 'Customer Model',
          updatedAt: '2026-09-24T10:00:00.000Z',
        ),
        EquipmentEntity(
          id: 'equipment-organization',
          organizationId: 'org-a',
          ownerType: EquipmentOwnerType.organization,
          organizationPurpose: EquipmentOrganizationPurpose.resale,
          type: 'Notebook',
          brand: 'Organization Brand',
          model: 'Organization Model',
          updatedAt: '2026-09-24T10:00:00.000Z',
        ),
      ];
}
