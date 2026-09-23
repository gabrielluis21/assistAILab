import 'dart:async';
import 'dart:convert';

import 'package:assistailab/core/database/service_order_repository.dart';
import 'package:assistailab/core/sync/sync_projection_applier.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/service_orders/application/service_order_remote_reader.dart';
import 'package:assistailab/features/service_orders/data/datasources/service_order_read_remote_datasource.dart';
import 'package:assistailab/features/service_orders/data/dtos/service_order_read_dto.dart';
import 'package:assistailab/features/service_orders/data/mappers/service_order_projection_mapper.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _orderId = '10000000-0000-4000-8000-000000000001';
const _otherOrderId = '10000000-0000-4000-8000-000000000002';
const _organizationId = '20000000-0000-4000-8000-000000000002';
const _customerId = '30000000-0000-4000-8000-000000000003';
const _equipmentId = '40000000-0000-4000-8000-000000000004';
const _technicianId = '50000000-0000-4000-8000-000000000005';
const _itemId = '60000000-0000-4000-8000-000000000006';
const _partId = '70000000-0000-4000-8000-000000000007';

const _staffScope = ProfessionalAuthScope(
  userId: _technicianId,
  organizationId: _organizationId,
);
const _customerScope = CustomerAuthScope(
  userId: '90000000-0000-4000-8000-000000000009',
  customerId: _customerId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('DTO and mapper', () {
    test('valid administrative list and detail envelopes are distinct DTOs',
        () {
      final list = ServiceOrderAdministrativeDto.listFromEnvelope({
        'orders': [_administrativeWire()],
      });
      final detail = ServiceOrderAdministrativeDto.detailFromEnvelope({
        'order': _administrativeWire(),
      });

      expect(list.single.id, _orderId);
      expect(detail.id, _orderId);
      expect(detail.organization['id'], _organizationId);
      expect(detail.createdAt, '2026-09-23T10:00:00.000Z');
    });

    test('invalid administrative envelope fails closed', () {
      expect(
        () => ServiceOrderAdministrativeDto.detailFromEnvelope({
          'orders': [_administrativeWire()],
        }),
        throwsFormatException,
      );
      final divergent = _administrativeWire();
      (divergent['organization'] as Map<String, dynamic>)['id'] = _customerId;
      expect(
        () => ServiceOrderAdministrativeDto.fromWire(divergent),
        throwsFormatException,
      );
    });

    test('Projection v2 rejects a different contractVersion', () {
      final wire = _staffProjectionWire()..['contractVersion'] = 1;
      expect(
        () => ServiceOrderProjectionDto.fromWire(
          wire,
          audience: ServiceOrderProjectionAudience.staff,
        ),
        throwsFormatException,
      );
    });

    test('CUSTOMER minimized Projection v2 contains no privileged fields', () {
      final dto = ServiceOrderProjectionDto.fromWire(
        _customerProjectionWire(),
        audience: ServiceOrderProjectionAudience.customer,
      );
      final mapped = ServiceOrderProjectionMapper.toSyncRecord(dto);
      final data = mapped['data'] as Map<String, dynamic>;

      expect(dto.organizationId, isNull);
      expect(dto.technicianId, isNull);
      for (final privateKey in const [
        'organizationId',
        'technicianId',
        'currentQuoteRevisionId',
        'lastApprovedQuoteRevisionId',
        'materializedQuoteRevisionId',
        'commercialScopeSource',
      ]) {
        expect(data, isNot(contains(privateKey)));
      }
      expect(
        (data['items'] as List).single,
        isNot(containsPair('partId', _partId)),
      );
    });

    test('CUSTOMER rejects a rich STAFF representation instead of filtering it',
        () {
      expect(
        () => ServiceOrderProjectionDto.fromWire(
          _staffProjectionWire(),
          audience: ServiceOrderProjectionAudience.customer,
        ),
        throwsFormatException,
      );
    });

    test('STAFF rich Projection v2 preserves projection metadata in its DTO',
        () {
      final dto = ServiceOrderProjectionDto.fromWire(
        _staffProjectionWire(revision: '9007199254740993'),
        audience: ServiceOrderProjectionAudience.staff,
      );
      expect(dto.organizationId, _organizationId);
      expect(dto.technicianId, _technicianId);
      expect(dto.projectionRevision, '9007199254740993');
      expect(dto.items.single.partId, _partId);
    });
  });

  group('remote HTTP boundary', () {
    test('uses list, envelope detail and Projection v2 routes', () async {
      final paths = <String>[];
      final remote = HttpServiceOrderReadRemoteDataSource.forTesting(
        get: (path) async {
          paths.add(path);
          if (path == '/service-orders') {
            return http.Response(
              jsonEncode({
                'orders': [_administrativeWire()]
              }),
              200,
            );
          }
          if (path.endsWith('/projection')) {
            return http.Response(jsonEncode(_staffProjectionWire()), 200);
          }
          return http.Response(
            jsonEncode({'order': _administrativeWire()}),
            200,
          );
        },
      );

      expect(await remote.readAdministrativeList(_staffScope), hasLength(1));
      expect(
        (await remote.readAdministrativeDetail(_orderId, _staffScope)).id,
        _orderId,
      );
      expect(
        (await remote.readProjection(
          _orderId,
          audience: ServiceOrderProjectionAudience.staff,
        ))
            .id,
        _orderId,
      );
      expect(paths, [
        '/service-orders',
        '/service-orders/$_orderId',
        '/service-orders/$_orderId/projection',
      ]);
    });

    test('invalid JSON fails closed', () async {
      final remote = HttpServiceOrderReadRemoteDataSource.forTesting(
        get: (_) async => http.Response('not-json', 200),
      );
      await expectLater(
        remote.readProjection(
          _orderId,
          audience: ServiceOrderProjectionAudience.staff,
        ),
        throwsA(
          isA<ServiceOrderReadException>().having(
            (error) => error.kind,
            'kind',
            ServiceOrderReadFailureKind.invalidPayload,
          ),
        ),
      );
    });

    for (final status in [401, 403, 404, 409, 422, 500]) {
      test('HTTP $status is explicit and never becomes valid data', () async {
        final remote = HttpServiceOrderReadRemoteDataSource.forTesting(
          get: (_) async => http.Response('{"error":"READ_REJECTED"}', status),
        );
        await expectLater(
          remote.readProjection(
            _orderId,
            audience: ServiceOrderProjectionAudience.staff,
          ),
          throwsA(
            isA<ServiceOrderReadException>()
                .having((error) => error.statusCode, 'statusCode', status)
                .having((error) => error.code, 'code', 'READ_REJECTED'),
          ),
        );
      });
    }

    test('timeout is explicit', () async {
      final gate = Completer<http.Response>();
      final remote = HttpServiceOrderReadRemoteDataSource.forTesting(
        get: (_) => gate.future,
        timeout: const Duration(milliseconds: 1),
      );
      await expectLater(
        remote.readProjection(
          _orderId,
          audience: ServiceOrderProjectionAudience.staff,
        ),
        throwsA(
          isA<ServiceOrderReadException>().having(
            (error) => error.kind,
            'kind',
            ServiceOrderReadFailureKind.timeout,
          ),
        ),
      );
    });
  });

  group('local Projection v2 writer', () {
    test('preserves organization, revision and fingerprint outside entity',
        () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      final dto = ServiceOrderProjectionDto.fromWire(
        _staffProjectionWire(revision: '7'),
        audience: ServiceOrderProjectionAudience.staff,
      );

      await SyncProjectionApplier.applyRecord(
        db,
        ServiceOrderProjectionMapper.toSyncRecord(dto),
      );

      final row = (await db.query('service_orders')).single;
      expect(row['organization_id'], _organizationId);
      expect(row['projection_revision'], '7');
      expect(row['projection_fingerprint'], isNotEmpty);

      final entity = await ServiceOrderLocalDataSource().findById(
        _orderId,
        executor: db,
      );
      expect(entity?.status, ServiceOrderStatusEnum.diagnostico);
      expect(entity?.totalAmount.minorUnits, 1000);
      expect(entity?.equipmentId, _equipmentId);
    });

    test('CUSTOMER projection persists no private identities', () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      final dto = ServiceOrderProjectionDto.fromWire(
        _customerProjectionWire(),
        audience: ServiceOrderProjectionAudience.customer,
      );
      await SyncProjectionApplier.applyRecord(
        db,
        ServiceOrderProjectionMapper.toSyncRecord(dto),
      );

      final row = (await db.query('service_orders')).single;
      expect(row['organization_id'], isNull);
      expect(row['customer_id'], isNull);
      expect(row['technician_id'], isNull);
      final item = (await db.query('service_order_items')).single;
      expect(item['part_id'], isNull);
      expect(item['id'], 'customer:$_orderId:0');
    });

    test('older remote projection cannot overwrite a newer local revision',
        () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      await _applyStaff(db, revision: '10', status: 'EM_EXECUCAO');
      await _applyStaff(db, revision: '9', status: 'DIAGNOSTICO');
      final row = (await db.query('service_orders')).single;
      expect(row['projection_revision'], '10');
      expect(row['status'], 'EM_EXECUCAO');
    });

    test('pending local order mutation rejects remote overwrite atomically',
        () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      await _applyStaff(db, revision: '1', status: 'DIAGNOSTICO');
      await _insertOutbox(
        db,
        entityType: 'SERVICE_ORDER',
        entityId: _orderId,
        payload: {'customerId': _customerId},
      );

      await expectLater(
        _applyStaff(db, revision: '2', status: 'EM_EXECUCAO'),
        throwsA(
          isA<SyncProjectionException>().having(
            (error) => error.code,
            'code',
            'SYNC_LOCAL_MUTATION_PENDING',
          ),
        ),
      );
      final row = (await db.query('service_orders')).single;
      expect(row['projection_revision'], '1');
      expect(row['status'], 'DIAGNOSTICO');
    });

    test('pending local item mutation also protects its aggregate', () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      await _applyStaff(db, revision: '1');
      await _insertOutbox(
        db,
        entityType: 'SERVICE_ORDER_ITEM',
        entityId: _itemId,
        payload: {'serviceOrderId': _orderId},
      );

      await expectLater(
        _applyStaff(db, revision: '2'),
        throwsA(isA<SyncProjectionException>()),
      );
      expect(
        (await db.query('service_orders')).single['projection_revision'],
        '1',
      );
    });

    test('SYNCED Outbox is terminal and allows later convergence', () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      await _applyStaff(db, revision: '1');
      await _insertOutbox(
        db,
        entityType: 'SERVICE_ORDER',
        entityId: _orderId,
        payload: {'customerId': _customerId},
        status: 'SYNCED',
      );
      await _applyStaff(db, revision: '2', status: 'EM_EXECUCAO');
      expect(
          (await db.query('service_orders')).single['status'], 'EM_EXECUCAO');
    });
  });

  group('session and concurrency isolation', () {
    test('CUSTOMER cannot invoke rich administrative reads', () async {
      final remote = _ControlledRemote();
      final reader = ServiceOrderRemoteReader(
        scope: _customerScope,
        remote: remote,
        isBindingCurrent: () => true,
      );
      await expectLater(
        reader.readAdministrativeList(),
        throwsA(
          isA<ServiceOrderReadException>().having(
            (error) => error.code,
            'code',
            'CUSTOMER_ADMINISTRATIVE_READ_FORBIDDEN',
          ),
        ),
      );
      expect(remote.administrativeCalls, 0);
    });

    test('STAFF rejects a projection from another organization', () async {
      final reader = ServiceOrderRemoteReader(
        scope: const ProfessionalAuthScope(
          userId: _technicianId,
          organizationId: '20000000-0000-4000-8000-000000000099',
        ),
        remote: _ControlledRemote(),
        isBindingCurrent: () => true,
      );
      await expectLater(
        reader.readProjection(_orderId),
        throwsA(
          isA<ServiceOrderReadException>().having(
            (error) => error.code,
            'code',
            'SERVICE_ORDER_TENANT_RESPONSE_MISMATCH',
          ),
        ),
      );
    });

    for (final scenario in [
      'session switch',
      'logout during GET',
      'late CUSTOMER response after switch to STAFF',
      'late STAFF response after switch to CUSTOMER',
    ]) {
      test('$scenario rejects the stale response', () async {
        var current = true;
        final gate = Completer<ServiceOrderProjectionDto>();
        final remote = _ControlledRemote(onProjection: (_, __) => gate.future);
        final reader = ServiceOrderRemoteReader(
          scope: scenario.contains('CUSTOMER response')
              ? _customerScope
              : _staffScope,
          remote: remote,
          isBindingCurrent: () => current,
        );

        final future = reader.readProjection(_orderId);
        await Future<void>.delayed(Duration.zero);
        current = false;
        gate.complete(
          ServiceOrderProjectionDto.fromWire(
            scenario.contains('CUSTOMER response')
                ? _customerProjectionWire()
                : _staffProjectionWire(),
            audience: scenario.contains('CUSTOMER response')
                ? ServiceOrderProjectionAudience.customer
                : ServiceOrderProjectionAudience.staff,
          ),
        );
        await expectLater(
            future, throwsA(isA<SessionRequestBlockedException>()));
      });
    }

    test('two concurrent GETs retain their own identities', () async {
      final first = Completer<ServiceOrderProjectionDto>();
      final second = Completer<ServiceOrderProjectionDto>();
      final remote = _ControlledRemote(
        onProjection: (id, _) => id == _orderId ? first.future : second.future,
      );
      final reader = ServiceOrderRemoteReader(
        scope: _staffScope,
        remote: remote,
        isBindingCurrent: () => true,
      );

      final firstFuture = reader.readProjection(_orderId);
      final secondFuture = reader.readProjection(_otherOrderId);
      second.complete(
        ServiceOrderProjectionDto.fromWire(
          _staffProjectionWire(id: _otherOrderId),
          audience: ServiceOrderProjectionAudience.staff,
        ),
      );
      first.complete(
        ServiceOrderProjectionDto.fromWire(
          _staffProjectionWire(),
          audience: ServiceOrderProjectionAudience.staff,
        ),
      );

      expect((await firstFuture).id, _orderId);
      expect((await secondFuture).id, _otherOrderId);
    });

    test('transient GET concurrent with Sync Pull cannot write over SQLite',
        () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      await _applyStaff(db, revision: '1', status: 'DIAGNOSTICO');
      final gate = Completer<ServiceOrderProjectionDto>();
      final reader = ServiceOrderRemoteReader(
        scope: _staffScope,
        remote: _ControlledRemote(onProjection: (_, __) => gate.future),
        isBindingCurrent: () => true,
      );

      final getFuture = reader.readProjection(_orderId);
      await _applyStaff(db, revision: '3', status: 'EM_EXECUCAO');
      gate.complete(
        ServiceOrderProjectionDto.fromWire(
          _staffProjectionWire(revision: '2', status: 'DIAGNOSTICO'),
          audience: ServiceOrderProjectionAudience.staff,
        ),
      );
      expect((await getFuture).projectionRevision, '2');
      final row = (await db.query('service_orders')).single;
      expect(row['projection_revision'], '3');
      expect(row['status'], 'EM_EXECUCAO');
    });

    test('remote errors preserve the last valid local projection', () async {
      final db = await _openDatabase();
      addTearDown(db.close);
      await _applyStaff(db, revision: '4', status: 'EM_EXECUCAO');

      for (final status in [403, 404, 500]) {
        final remote = HttpServiceOrderReadRemoteDataSource.forTesting(
          get: (_) async => http.Response('{"error":"FAILED"}', status),
        );
        await expectLater(
          remote.readProjection(
            _orderId,
            audience: ServiceOrderProjectionAudience.staff,
          ),
          throwsA(isA<ServiceOrderReadException>()),
        );
        final row = (await db.query('service_orders')).single;
        expect(row['projection_revision'], '4');
        expect(row['status'], 'EM_EXECUCAO');
      }
    });
  });
}

final class _ControlledRemote implements ServiceOrderReadRemoteDataSource {
  _ControlledRemote({this.onProjection});

  final Future<ServiceOrderProjectionDto> Function(
    String id,
    ServiceOrderProjectionAudience audience,
  )? onProjection;
  int administrativeCalls = 0;

  @override
  Future<List<ServiceOrderAdministrativeDto>> readAdministrativeList(
    ProfessionalAuthScope scope,
  ) async {
    administrativeCalls++;
    return const [];
  }

  @override
  Future<ServiceOrderAdministrativeDto> readAdministrativeDetail(
    String id,
    ProfessionalAuthScope scope,
  ) {
    administrativeCalls++;
    return Future.value(
      ServiceOrderAdministrativeDto.fromWire(_administrativeWire(id: id)),
    );
  }

  @override
  Future<ServiceOrderProjectionDto> readProjection(
    String id, {
    required ServiceOrderProjectionAudience audience,
  }) {
    final callback = onProjection;
    if (callback != null) return callback(id, audience);
    return Future.value(
      ServiceOrderProjectionDto.fromWire(
        audience == ServiceOrderProjectionAudience.customer
            ? _customerProjectionWire(id: id)
            : _staffProjectionWire(id: id),
        audience: audience,
      ),
    );
  }
}

Map<String, dynamic> _administrativeWire({String id = _orderId}) => {
      'id': id,
      'friendlyId': 10,
      'organizationId': _organizationId,
      'customerId': _customerId,
      'equipmentId': _equipmentId,
      'technicianId': _technicianId,
      'financeCoreVersion': 2,
      'currentQuoteRevisionId': null,
      'lastApprovedQuoteRevisionId': null,
      'status': 'DIAGNOSTICO',
      'problemDescription': 'Nao liga',
      'diagnosis': null,
      'solution': null,
      'totalAmount': '10.00',
      'createdAt': '2026-09-23T10:00:00.000Z',
      'updatedAt': '2026-09-23T10:01:00.000Z',
      'organization': {'id': _organizationId, 'name': 'Assistencia'},
      'customer': {
        'id': _customerId,
        'name': 'Cliente',
        'document': null,
        'email': null,
        'phone': null,
        'address': null,
        'createdAt': '2026-09-20T10:00:00.000Z',
        'updatedAt': '2026-09-20T10:00:00.000Z',
      },
      'equipment': {
        'id': _equipmentId,
        'customerId': _customerId,
        'organizationId': null,
        'ownerType': 'CUSTOMER',
        'organizationPurpose': null,
        'brand': 'Marca',
        'model': 'Modelo',
        'serialNumber': null,
        'type': 'Notebook',
        'notes': null,
        'createdAt': '2026-09-20T10:00:00.000Z',
        'updatedAt': '2026-09-20T10:00:00.000Z',
      },
      'technician': {'id': _technicianId, 'name': 'Tecnico'},
    };

Map<String, dynamic> _staffProjectionWire({
  String id = _orderId,
  String revision = '2',
  String status = 'DIAGNOSTICO',
}) =>
    {
      'contractVersion': 2,
      'projectionRevision': revision,
      'id': id,
      'friendlyId': 10,
      'organizationId': _organizationId,
      'customerId': _customerId,
      'equipmentId': _equipmentId,
      'technicianId': _technicianId,
      'status': status,
      'problemDescription': 'Nao liga',
      'solution': null,
      'createdAt': '2026-09-23T10:00:00.000Z',
      'updatedAt': '2026-09-23T10:01:00.000Z',
      'diagnosis': 'Fonte com defeito',
      'totalAmountMinor': 1000,
      'currentQuoteRevisionId': null,
      'lastApprovedQuoteRevisionId': null,
      'materializedQuoteRevisionId': null,
      'commercialScopeSource': 'UNPUBLISHED',
      'items': [
        {
          'id': _itemId,
          'serviceOrderId': id,
          'partId': _partId,
          'description': 'Servico',
          'quantity': 2,
          'unitPriceMinor': 500,
          'totalPriceMinor': 1000,
          'createdAt': '2026-09-23T10:00:00.000Z',
        }
      ],
    };

Map<String, dynamic> _customerProjectionWire({String id = _orderId}) => {
      'contractVersion': 2,
      'projectionRevision': '2',
      'id': id,
      'friendlyId': 10,
      'equipmentId': _equipmentId,
      'status': 'AGUARDANDO_APROVACAO',
      'problemDescription': 'Nao liga',
      'solution': null,
      'createdAt': '2026-09-23T10:00:00.000Z',
      'updatedAt': '2026-09-23T10:01:00.000Z',
      'diagnosis': 'Fonte com defeito',
      'totalAmountMinor': 1000,
      'items': [
        {
          'description': 'Servico',
          'quantity': 2,
          'unitPriceMinor': 500,
          'totalPriceMinor': 1000,
        }
      ],
    };

Future<void> _applyStaff(
  Database db, {
  required String revision,
  String status = 'DIAGNOSTICO',
}) {
  final dto = ServiceOrderProjectionDto.fromWire(
    _staffProjectionWire(revision: revision, status: status),
    audience: ServiceOrderProjectionAudience.staff,
  );
  return SyncProjectionApplier.applyRecord(
    db,
    ServiceOrderProjectionMapper.toSyncRecord(dto),
  );
}

Future<void> _insertOutbox(
  Database db, {
  required String entityType,
  required String entityId,
  required Map<String, dynamic> payload,
  String status = 'PENDING',
}) {
  return db.insert('outbox', {
    'operation_id': 'operation-$entityType-$entityId',
    'entity_type': entityType,
    'entity_id': entityId,
    'operation_type': 'UPDATE',
    'payload': jsonEncode(payload),
    'created_at': '2026-09-23T10:02:00.000Z',
    'status': status,
  });
}

Future<Database> _openDatabase() {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE service_orders (
          id TEXT PRIMARY KEY, friendly_id INTEGER, organization_id TEXT,
          customer_id TEXT, equipment_id TEXT NOT NULL, technician_id TEXT,
          status TEXT NOT NULL, problem_description TEXT NOT NULL,
          diagnosis TEXT, solution TEXT, total_amount_minor INTEGER NOT NULL,
          projection_revision TEXT, projection_fingerprint TEXT,
          updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE service_order_items (
          id TEXT PRIMARY KEY, service_order_id TEXT NOT NULL, part_id TEXT,
          description TEXT NOT NULL, quantity INTEGER NOT NULL,
          unit_price_minor INTEGER NOT NULL, total_price_minor INTEGER NOT NULL,
          updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE outbox (
          operation_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL, operation_type TEXT NOT NULL,
          payload TEXT NOT NULL, created_at TEXT NOT NULL,
          status TEXT NOT NULL)''');
      },
    ),
  );
}
