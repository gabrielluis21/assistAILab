import 'dart:async';
import 'dart:convert';

import 'package:assistailab/core/commands/command_intent.dart';
import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/equipment/equipment_acquisition_command_executor.dart';
import 'package:assistailab/features/equipment/equipment_acquisition_entity.dart';
import 'package:assistailab/features/equipment/equipment_acquisition_gateway.dart';
import 'package:assistailab/features/equipment/equipment_acquisition_repository.dart';
import 'package:assistailab/features/equipment/equipment_entity.dart';
import 'package:assistailab/features/equipment/pre_acquisition_entity.dart';
import 'package:assistailab/features/equipment/pre_acquisition_repository.dart';
import 'package:assistailab/features/equipment/pre_acquisitions_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database database;

  setUp(() async {
    database = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await database.execute('''
      CREATE TABLE command_intents (
        operation_id TEXT PRIMARY KEY,
        command_type TEXT NOT NULL,
        target_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        lifecycle_state TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await database.execute('''
      CREATE UNIQUE INDEX command_intents_unresolved_identity
      ON command_intents(command_type, target_id, payload_json)
      WHERE lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')
    ''');
    await database.execute('''
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
    await SqliteDatabase.ensurePreAcquisitionSchema(database);
    await SqliteDatabase.ensureEquipmentAcquisitionSchema(database);
  });

  tearDown(() async {
    await database.close();
  });

  group('P08-C SQLite projection', () {
    test('enforces source correlation and backend enum boundaries', () async {
      final valid = _acquisition();
      await EquipmentAcquisitionLocalDataSource().upsert(
        valid,
        executor: database,
      );
      expect(
        (await EquipmentAcquisitionLocalDataSource().findById(
          valid.id,
          executor: database,
        ))
            ?.source,
        EquipmentAcquisitionSource.directOffer,
      );

      final invalid = valid.toMap()
        ..['id'] = 'acquisition-invalid'
        ..['source'] = 'DIRECT_OFFER'
        ..['service_order_id'] = 'service-order-forbidden';
      await expectLater(
        database.insert('equipment_acquisitions', invalid),
        throwsA(anything),
      );
    });

    test('never creates a second idempotency or retry table', () async {
      final tables = await database.query(
        'sqlite_master',
        columns: ['name'],
        where: "type = 'table'",
      );
      expect(
        tables.map((row) => row['name']),
        containsAll(<String>{
          'command_intents',
          'pre_acquisitions',
          'equipment_acquisitions',
        }),
      );
      expect(
        tables.map((row) => row['name']),
        isNot(contains('equipment_acquisition_outbox')),
      );
    });

    test('authoritative completion updates Equipment ownership without Outbox',
        () async {
      await database.insert('equipments', {
        'id': 'equipment-1',
        'customer_id': 'customer-1',
        'organization_id': null,
        'owner_type': 'CUSTOMER',
        'organization_purpose': null,
        'type': 'Notebook',
        'brand': 'Brand',
        'model': 'Model',
        'serial_number': null,
        'notes': 'preserved',
        'updated_at': '2026-09-29T10:00:00.000Z',
      });
      await EquipmentAcquisitionLocalDataSource().upsert(
        _acquisition(
          status: EquipmentAcquisitionStatus.completed,
          equipmentSnapshot: const EquipmentAcquisitionEquipmentSnapshot(
            id: 'equipment-1',
            customerId: null,
            organizationId: 'organization-1',
            ownerType: EquipmentOwnerType.organization,
            organizationPurpose: EquipmentOrganizationPurpose.resale,
            type: 'Notebook',
            brand: 'Brand',
            model: 'Model',
            serialNumber: null,
          ),
        ),
        executor: database,
      );

      final equipment =
          (await database.query('equipments', where: 'id = ?', whereArgs: [
        'equipment-1',
      ]))
              .single;
      expect(equipment['owner_type'], 'ORGANIZATION');
      expect(equipment['customer_id'], isNull);
      expect(equipment['organization_id'], 'organization-1');
      expect(equipment['organization_purpose'], 'RESALE');
      expect(equipment['notes'], 'preserved');
    });
  });

  group('P08-C HTTP contract', () {
    test('SERVICE_ORDER and DIRECT_OFFER use their frozen endpoints', () async {
      final calls = <({String endpoint, Map<String, dynamic>? body})>[];
      final gateway = EquipmentAcquisitionHttpGateway.forTesting(
        get: (_) async => http.Response('{}', 200),
        post: (endpoint, {body, headers = const {}}) async {
          expect(headers.keys, ['X-Operation-Id']);
          calls.add((endpoint: endpoint, body: body));
          final source = body!['source'] as String;
          return http.Response(
            jsonEncode({
              'acquisition': _wire(
                source: source,
                serviceOrderId: body['serviceOrderId'] as String?,
                clientPreAcquisitionId:
                    body['clientPreAcquisitionId'] as String?,
              ),
            }),
            201,
          );
        },
      );

      await gateway.create(
        operationId: 'operation-service',
        source: EquipmentAcquisitionSource.serviceOrder,
        equipmentId: 'equipment-1',
        serviceOrderId: 'service-order-1',
        purpose: EquipmentAcquisitionPurpose.resale,
        offeredAmountMinor: 125001,
        notes: '  proposta  ',
        clientPreAcquisitionId: 'pre-service',
      );
      await gateway.create(
        operationId: 'operation-direct',
        source: EquipmentAcquisitionSource.directOffer,
        equipmentId: 'equipment-1',
        serviceOrderId: null,
        purpose: EquipmentAcquisitionPurpose.partsDonor,
        offeredAmountMinor: null,
        notes: null,
        clientPreAcquisitionId: 'pre-direct',
      );

      expect(calls[0].endpoint, '/equipment-acquisitions');
      expect(calls[0].body!['serviceOrderId'], 'service-order-1');
      expect(calls[0].body!['notes'], 'proposta');
      expect(calls[1].endpoint, '/equipment-acquisitions/direct-offer');
      expect(calls[1].body!.containsKey('serviceOrderId'), isFalse);
    });

    test('all transition calls send X-Operation-Id and exact P08-B bodies',
        () async {
      final calls = <({String endpoint, Map<String, dynamic>? body})>[];
      final gateway = EquipmentAcquisitionHttpGateway.forTesting(
        get: (_) async => http.Response('{}', 200),
        post: (endpoint, {body, headers = const {}}) async {
          expect(headers['X-Operation-Id'], isNotEmpty);
          calls.add((endpoint: endpoint, body: body));
          final status = endpoint.endsWith('/reject')
              ? 'REJECTED'
              : endpoint.endsWith('/complete')
                  ? 'COMPLETED'
                  : 'AUTHORIZED';
          return http.Response(
            jsonEncode({
              'acquisition': _wire(
                status: status,
                consentMethod: endpoint.endsWith('/authorize-in-person')
                    ? 'IN_PERSON_ASSISTED'
                    : endpoint.endsWith('/authorize')
                        ? 'CUSTOMER_APP'
                        : null,
              ),
            }),
            200,
          );
        },
      );

      await gateway.authorize(
        operationId: 'op-authorize',
        acquisitionId: 'acquisition-1',
        consentMethod: EquipmentConsentMethod.customerApp,
      );
      await gateway.reject(
        operationId: 'op-reject',
        acquisitionId: 'acquisition-1',
      );
      await gateway.authorizeInPerson(
        operationId: 'op-assisted',
        acquisitionId: 'acquisition-1',
      );
      await gateway.complete(
        operationId: 'op-complete',
        acquisitionId: 'acquisition-1',
      );

      expect(
        calls.map((call) => call.endpoint),
        [
          '/equipment-acquisitions/acquisition-1/authorize',
          '/equipment-acquisitions/acquisition-1/reject',
          '/equipment-acquisitions/acquisition-1/authorize-in-person',
          '/equipment-acquisitions/acquisition-1/complete',
        ],
      );
      expect(calls[0].body, {'consentMethod': 'CUSTOMER_APP'});
      expect(calls[1].body, isEmpty);
      expect(calls[2].body, {'consentMethod': 'IN_PERSON_ASSISTED'});
      expect(calls[3].body, isEmpty);
    });
  });

  group('P08-C shared CommandIntent lifecycle', () {
    test('CREATE atomically commits projection and approves PreAcquisition',
        () async {
      final pre = _preAcquisition();
      await PreAcquisitionLocalDataSource().insert(
        pre,
        executor: database,
      );
      final gateway = _FakeGateway(createResult: _acquisition());

      final created =
          await _executor(database, gateway).createFromPreAcquisition(
        preAcquisition: pre,
        purpose: EquipmentAcquisitionPurpose.resale,
      );

      expect(created.status, EquipmentAcquisitionStatus.pending);
      expect(gateway.createSources, [EquipmentAcquisitionSource.directOffer]);
      expect(
        (await PreAcquisitionLocalDataSource().findById(
          pre.id,
          executor: database,
        ))
            ?.status,
        PreAcquisitionStatus.approved,
      );
      expect(
        (await EquipmentAcquisitionLocalDataSource().listAll(
          executor: database,
        ))
            .single
            .id,
        created.id,
      );
      expect(
        (await database.query('command_intents')).single['lifecycle_state'],
        'COMPLETED',
      );
    });

    test('SERVICE_ORDER source is derived only from the local correlation',
        () async {
      final pre = _preAcquisition(serviceOrderId: 'service-order-1');
      await PreAcquisitionLocalDataSource().insert(pre, executor: database);
      final gateway = _FakeGateway(
        createResult: _acquisition(
          source: EquipmentAcquisitionSource.serviceOrder,
          serviceOrderId: 'service-order-1',
        ),
      );

      await _executor(database, gateway).createFromPreAcquisition(
        preAcquisition: pre,
        purpose: EquipmentAcquisitionPurpose.resale,
      );

      expect(
        gateway.createSources,
        [EquipmentAcquisitionSource.serviceOrder],
      );
      expect(gateway.createServiceOrderIds, ['service-order-1']);
    });

    test('unknown failure retries with the same operation id', () async {
      final pre = _preAcquisition();
      await PreAcquisitionLocalDataSource().insert(pre, executor: database);
      final gateway = _FakeGateway(
        createResult: _acquisition(),
        createErrors: [TimeoutException('lost response')],
      );
      var generated = 0;
      final executor = _executor(
        database,
        gateway,
        operationIdFactory: () => 'operation-${++generated}',
      );

      await expectLater(
        executor.createFromPreAcquisition(
          preAcquisition: pre,
          purpose: EquipmentAcquisitionPurpose.resale,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        (await database.query('command_intents')).single['lifecycle_state'],
        'UNKNOWN',
      );

      await executor.createFromPreAcquisition(
        preAcquisition: pre,
        purpose: EquipmentAcquisitionPurpose.resale,
      );
      expect(gateway.operationIds, ['operation-1', 'operation-1']);
      expect(generated, 1);
    });

    test('definitive rejection does not commit a local projection', () async {
      final pre = _preAcquisition();
      await PreAcquisitionLocalDataSource().insert(pre, executor: database);
      final gateway = _FakeGateway(
        createResult: _acquisition(),
        createErrors: const [
          EquipmentAcquisitionCommandException(
            409,
            'EQUIPMENT_ACTIVE_ACQUISITION_EXISTS',
          ),
        ],
      );

      await expectLater(
        _executor(database, gateway).createFromPreAcquisition(
          preAcquisition: pre,
          purpose: EquipmentAcquisitionPurpose.resale,
        ),
        throwsA(isA<EquipmentAcquisitionCommandException>()),
      );
      expect(await database.query('equipment_acquisitions'), isEmpty);
      expect(
        (await database.query('command_intents')).single['lifecycle_state'],
        'REJECTED',
      );
      expect(
        (await PreAcquisitionLocalDataSource().findById(
          pre.id,
          executor: database,
        ))
            ?.status,
        PreAcquisitionStatus.pendingEvaluation,
      );
    });

    test('AUTHORIZE, REJECT, AUTHORIZE_IN_PERSON and COMPLETE are durable',
        () async {
      final repository = EquipmentAcquisitionLocalDataSource();
      await repository.upsert(_acquisition(), executor: database);
      final gateway = _FakeGateway(createResult: _acquisition());
      var operation = 0;
      final executor = _executor(
        database,
        gateway,
        operationIdFactory: () => 'transition-${++operation}',
      );

      await executor.authorize(
        acquisitionId: 'acquisition-1',
        consentMethod: EquipmentConsentMethod.digitalSignature,
      );
      expect(
        (await repository.findById('acquisition-1', executor: database))
            ?.status,
        EquipmentAcquisitionStatus.authorized,
      );

      await repository.upsert(_acquisition(), executor: database);
      await executor.reject(acquisitionId: 'acquisition-1');
      expect(
        (await repository.findById('acquisition-1', executor: database))
            ?.status,
        EquipmentAcquisitionStatus.rejected,
      );

      await repository.upsert(_acquisition(), executor: database);
      await executor.authorizeInPerson(acquisitionId: 'acquisition-1');
      expect(
        (await repository.findById('acquisition-1', executor: database))
            ?.consentMethod,
        EquipmentConsentMethod.inPersonAssisted,
      );

      await executor.complete(acquisitionId: 'acquisition-1');
      expect(
        (await repository.findById('acquisition-1', executor: database))
            ?.status,
        EquipmentAcquisitionStatus.completed,
      );
      expect(
        (await database.query('command_intents')).map(
          (row) => row['command_type'],
        ),
        containsAll(equipmentAcquisitionOwnedCommandTypes.difference({
          equipmentAcquisitionCreateCommandType,
        })),
      );
    });

    test('stale session fails closed before intent creation or dispatch',
        () async {
      final gateway = _FakeGateway(createResult: _acquisition());
      final executor = _executor(database, gateway, isCurrent: () => false);

      await expectLater(
        executor.complete(acquisitionId: 'acquisition-1'),
        throwsA(isA<StateError>()),
      );
      expect(await database.query('command_intents'), isEmpty);
      expect(gateway.operationIds, isEmpty);
    });
  });

  group('P08-C authenticated projection isolation', () {
    test('professional and customer scopes reject cross-tenant list data',
        () async {
      for (final scope in const <AuthScope>[
        ProfessionalAuthScope(userId: 'staff-a', organizationId: 'other-org'),
        CustomerAuthScope(userId: 'customer-a', customerId: 'other-customer'),
      ]) {
        final manager = AuthScopedDatabaseManager.forTesting(
          opener: (_) async => database,
          closer: (_) async {},
        );
        final handle = await manager.openDatabaseForScope(
          scope,
          sessionGeneration: 1,
        );
        final key = AuthenticatedSessionKey(
          scope: scope,
          sessionGeneration: handle.sessionGeneration,
        );
        final container = ProviderContainer(
          overrides: [
            authenticatedSessionKeyProvider.overrideWithValue(key),
            isOnlineSessionProvider.overrideWithValue(true),
            equipmentAcquisitionDatabaseManagerProvider
                .overrideWithValue(manager),
            equipmentAcquisitionGatewayProvider.overrideWithValue(
              _FakeGateway(createResult: _acquisition()),
            ),
          ],
        );

        await expectLater(
          container.read(equipmentAcquisitionsProvider.future),
          throwsA(isA<StateError>()),
        );
        expect(await database.query('equipment_acquisitions'), isEmpty);
        container.dispose();
      }
    });

    test('matching customer scope publishes only its authoritative records',
        () async {
      const scope = CustomerAuthScope(
        userId: 'customer-user',
        customerId: 'customer-1',
      );
      final manager = AuthScopedDatabaseManager.forTesting(
        opener: (_) async => database,
        closer: (_) async {},
      );
      final handle = await manager.openDatabaseForScope(
        scope,
        sessionGeneration: 1,
      );
      final container = ProviderContainer(
        overrides: [
          authenticatedSessionKeyProvider.overrideWithValue(
            AuthenticatedSessionKey(
              scope: scope,
              sessionGeneration: handle.sessionGeneration,
            ),
          ),
          isOnlineSessionProvider.overrideWithValue(true),
          equipmentAcquisitionDatabaseManagerProvider.overrideWithValue(
            manager,
          ),
          equipmentAcquisitionGatewayProvider.overrideWithValue(
            _FakeGateway(createResult: _acquisition()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final records =
          await container.read(equipmentAcquisitionsProvider.future);

      expect(records.single.customerId, scope.customerId);
      expect(
        (await database.query('equipment_acquisitions')).single['customer_id'],
        scope.customerId,
      );
    });
  });
}

EquipmentAcquisitionCommandExecutor _executor(
  Database database,
  EquipmentAcquisitionGateway gateway, {
  String Function()? operationIdFactory,
  bool Function()? isCurrent,
}) {
  return EquipmentAcquisitionCommandExecutor(
    gateway: gateway,
    acquisitionRepository: EquipmentAcquisitionLocalDataSource(),
    preAcquisitionRepository: PreAcquisitionLocalDataSource(),
    intentRepository: CommandIntentLocalDataSource(
      nowUtc: () => DateTime.utc(2026, 9, 29),
    ),
    database: database,
    isBindingCurrent: isCurrent ?? () => true,
    operationIdFactory: operationIdFactory ?? () => 'operation-id',
    nowUtc: () => DateTime.utc(2026, 9, 29, 12),
  );
}

PreAcquisitionEntity _preAcquisition({String? serviceOrderId}) =>
    PreAcquisitionEntity(
      id: 'pre-1',
      equipmentId: 'equipment-1',
      customerId: 'customer-1',
      organizationId: 'organization-1',
      serviceOrderId: serviceOrderId,
      status: PreAcquisitionStatus.pendingEvaluation,
      offeredAmountMinor: 125001,
      notes: 'Proposta local',
      createdAt: '2026-09-29T10:00:00.000Z',
      evaluationDeadline: '2026-10-06T10:00:00.000Z',
    );

EquipmentAcquisitionEntity _acquisition({
  EquipmentAcquisitionSource source = EquipmentAcquisitionSource.directOffer,
  String? serviceOrderId,
  EquipmentAcquisitionStatus status = EquipmentAcquisitionStatus.pending,
  EquipmentConsentMethod? consentMethod,
  EquipmentAcquisitionEquipmentSnapshot? equipmentSnapshot,
}) =>
    EquipmentAcquisitionEntity(
      id: 'acquisition-1',
      equipmentId: 'equipment-1',
      customerId: 'customer-1',
      organizationId: 'organization-1',
      serviceOrderId: serviceOrderId,
      source: source,
      clientPreAcquisitionId: 'pre-1',
      purpose: EquipmentAcquisitionPurpose.resale,
      status: status,
      offeredAmountMinor: 125001,
      consentMethod: consentMethod,
      authorizedAt: status == EquipmentAcquisitionStatus.authorized ||
              status == EquipmentAcquisitionStatus.completed
          ? '2026-09-29T11:00:00.000Z'
          : null,
      rejectedAt: status == EquipmentAcquisitionStatus.rejected
          ? '2026-09-29T11:00:00.000Z'
          : null,
      cancelledAt: null,
      completedAt: status == EquipmentAcquisitionStatus.completed
          ? '2026-09-29T12:00:00.000Z'
          : null,
      notes: 'Proposta local',
      createdAt: '2026-09-29T10:30:00.000Z',
      updatedAt: '2026-09-29T10:30:00.000Z',
      equipmentSnapshot: equipmentSnapshot,
    );

Map<String, Object?> _wire({
  String source = 'DIRECT_OFFER',
  String? serviceOrderId,
  String status = 'PENDING',
  String? consentMethod,
  String? clientPreAcquisitionId = 'pre-1',
}) =>
    {
      'id': 'acquisition-1',
      'equipmentId': 'equipment-1',
      'customerId': 'customer-1',
      'organizationId': 'organization-1',
      'serviceOrderId': serviceOrderId,
      'source': source,
      'clientPreAcquisitionId': clientPreAcquisitionId,
      'purpose': 'RESALE',
      'status': status,
      'offeredAmountMinor': 125001,
      'consentMethod': consentMethod,
      'authorizedAt': status == 'AUTHORIZED' || status == 'COMPLETED'
          ? '2026-09-29T11:00:00.000Z'
          : null,
      'rejectedAt': status == 'REJECTED' ? '2026-09-29T11:00:00.000Z' : null,
      'cancelledAt': null,
      'completedAt': status == 'COMPLETED' ? '2026-09-29T12:00:00.000Z' : null,
      'notes': 'Proposta local',
      'createdAt': '2026-09-29T10:30:00.000Z',
      'updatedAt': '2026-09-29T10:30:00.000Z',
    };

final class _FakeGateway implements EquipmentAcquisitionGateway {
  _FakeGateway({
    required this.createResult,
    List<Object>? createErrors,
  }) : createErrors = List.of(createErrors ?? const []);

  final EquipmentAcquisitionEntity createResult;
  final List<Object> createErrors;
  final List<String> operationIds = [];
  final List<EquipmentAcquisitionSource> createSources = [];
  final List<String?> createServiceOrderIds = [];

  @override
  Future<List<EquipmentAcquisitionEntity>> listAll() async => [createResult];

  @override
  Future<EquipmentAcquisitionEntity> create({
    required String operationId,
    required EquipmentAcquisitionSource source,
    required String equipmentId,
    required String? serviceOrderId,
    required EquipmentAcquisitionPurpose purpose,
    required int? offeredAmountMinor,
    required String? notes,
    required String clientPreAcquisitionId,
  }) async {
    operationIds.add(operationId);
    createSources.add(source);
    createServiceOrderIds.add(serviceOrderId);
    if (createErrors.isNotEmpty) throw createErrors.removeAt(0);
    return createResult;
  }

  @override
  Future<EquipmentAcquisitionEntity> authorize({
    required String operationId,
    required String acquisitionId,
    required EquipmentConsentMethod consentMethod,
  }) async {
    operationIds.add(operationId);
    return _acquisition(
      status: EquipmentAcquisitionStatus.authorized,
      consentMethod: consentMethod,
    );
  }

  @override
  Future<EquipmentAcquisitionEntity> reject({
    required String operationId,
    required String acquisitionId,
  }) async {
    operationIds.add(operationId);
    return _acquisition(status: EquipmentAcquisitionStatus.rejected);
  }

  @override
  Future<EquipmentAcquisitionEntity> authorizeInPerson({
    required String operationId,
    required String acquisitionId,
  }) async {
    operationIds.add(operationId);
    return _acquisition(
      status: EquipmentAcquisitionStatus.authorized,
      consentMethod: EquipmentConsentMethod.inPersonAssisted,
    );
  }

  @override
  Future<EquipmentAcquisitionEntity> complete({
    required String operationId,
    required String acquisitionId,
  }) async {
    operationIds.add(operationId);
    return _acquisition(status: EquipmentAcquisitionStatus.completed);
  }
}
