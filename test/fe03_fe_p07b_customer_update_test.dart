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
import 'package:assistailab/features/customers/customer_repository.dart';
import 'package:assistailab/features/customers/customers_page.dart';
import 'package:assistailab/features/customers/customers_provider.dart';
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
        Directory.systemTemp.createTempSync('fe03_p07b_customer_update_');
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

  group('FE03-P07-B local Customer update', () {
    test('valid update persists SQLite and exact Outbox mutation atomically',
        () async {
      await _seedCustomer(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      final subscription = container.listen(
        customersProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(customersProvider.future);

      await container.read(customersProvider.notifier).updateCustomer(
            id: 'customer-1',
            name: '  Novo Nome  ',
            document: '  123456  ',
            email: '  novo@example.test  ',
            phone: '  +55 11 99999-0000  ',
            address: '  Rua Atualizada, 10  ',
          );

      final customer = await CustomerLocalDataSource().findById(
        'customer-1',
        executor: handle.database,
      );
      expect(customer, isNotNull);
      expect(customer!.name, 'Novo Nome');
      expect(customer.document, '123456');
      expect(customer.email, 'novo@example.test');
      expect(customer.phone, '+55 11 99999-0000');
      expect(customer.address, 'Rua Atualizada, 10');

      final outbox = (await handle.database.query('outbox')).single;
      expect(outbox['entity_type'], 'CUSTOMER');
      expect(outbox['entity_id'], 'customer-1');
      expect(outbox['operation_type'], 'UPDATE');
      expect(outbox['status'], 'PENDING');
      expect(outbox['operation_id'], isA<String>());
      expect((outbox['operation_id'] as String).isNotEmpty, isTrue);
      expect(jsonDecode(outbox['payload'] as String), {
        'name': 'Novo Nome',
        'document': '123456',
        'email': 'novo@example.test',
        'phone': '+55 11 99999-0000',
        'address': 'Rua Atualizada, 10',
      });

      final published = container.read(customersProvider).requireValue.single;
      expect(published.name, 'Novo Nome');
    });

    test('nullable supported fields are cleared as null in SQLite and payload',
        () async {
      await _seedCustomer(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(customersProvider.future);

      await container.read(customersProvider.notifier).updateCustomer(
            id: 'customer-1',
            name: 'Nome Mantido',
            document: '   ',
            email: '',
            phone: null,
            address: ' ',
          );

      final customer = await CustomerLocalDataSource().findById(
        'customer-1',
        executor: handle.database,
      );
      expect(customer!.document, isNull);
      expect(customer.email, isNull);
      expect(customer.phone, isNull);
      expect(customer.address, isNull);
      expect(
          jsonDecode(
            (await handle.database.query('outbox')).single['payload'] as String,
          ),
          {
            'name': 'Nome Mantido',
            'document': null,
            'email': null,
            'phone': null,
            'address': null,
          });
    });

    test('Outbox failure rolls back Customer update', () async {
      await _seedCustomer(handle.database);
      final container = _container(
        sessionKey,
        outboxDao: _ThrowingOutboxDao(),
      );
      addTearDown(container.dispose);
      await container.read(customersProvider.future);

      await expectLater(
        container.read(customersProvider.notifier).updateCustomer(
              id: 'customer-1',
              name: 'Must roll back',
            ),
        throwsA(isA<StateError>()),
      );

      expect(await _customerName(handle.database, 'customer-1'), 'Original');
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('repository failure creates no partial Outbox mutation', () async {
      await _seedCustomer(handle.database);
      final container = _container(
        sessionKey,
        repository: _ThrowingCustomerRepository(
          CustomerLocalDataSource(),
        ),
      );
      addTearDown(container.dispose);
      await container.read(customersProvider.future);

      await expectLater(
        container.read(customersProvider.notifier).updateCustomer(
              id: 'customer-1',
              name: 'Must not persist',
            ),
        throwsA(isA<StateError>()),
      );

      expect(await _customerName(handle.database, 'customer-1'), 'Original');
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('unknown Customer id in current tenant fails before any mutation',
        () async {
      await _seedCustomer(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(customersProvider.future);

      await expectLater(
        container.read(customersProvider.notifier).updateCustomer(
              id: 'customer-from-another-tenant',
              name: 'Cross tenant attempt',
            ),
        throwsA(isA<StateError>()),
      );

      expect(await _customerName(handle.database, 'customer-1'), 'Original');
      expect(await handle.database.query('outbox'), isEmpty);
    });

    test('invalid Backend field bounds fail before SQLite and Outbox',
        () async {
      await _seedCustomer(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(customersProvider.future);

      await expectLater(
        container.read(customersProvider.notifier).updateCustomer(
              id: 'customer-1',
              name: '   ',
            ),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        container.read(customersProvider.notifier).updateCustomer(
              id: 'customer-1',
              name: 'Valid',
              document: 'x' * 101,
            ),
        throwsA(isA<ArgumentError>()),
      );

      expect(await _customerName(handle.database, 'customer-1'), 'Original');
      expect(await handle.database.query('outbox'), isEmpty);
    });
  });

  group('FE03-P07-B P07-A projection compatibility', () {
    test('PENDING and PROCESSING protect local update; SYNCED converges',
        () async {
      await _seedCustomer(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(customersProvider.future);
      await container.read(customersProvider.notifier).updateCustomer(
            id: 'customer-1',
            name: 'Local update',
          );

      final operationId =
          (await handle.database.query('outbox')).single['operation_id'];
      await expectLater(
        SyncProjectionApplier.applyChange(
          handle.database,
          _remoteCustomerChange('Remote stale'),
        ),
        throwsA(_pendingMutationException),
      );
      expect(
          await _customerName(handle.database, 'customer-1'), 'Local update');

      await handle.database.update(
        'outbox',
        {'status': 'PROCESSING'},
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      await expectLater(
        SyncProjectionApplier.applyChange(
          handle.database,
          _remoteCustomerChange('Remote still stale'),
        ),
        throwsA(_pendingMutationException),
      );
      expect(
          await _customerName(handle.database, 'customer-1'), 'Local update');

      await handle.database.update(
        'outbox',
        {'status': 'SYNCED'},
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      await SyncProjectionApplier.applyChange(
        handle.database,
        _remoteCustomerChange('Server confirmed'),
      );
      expect(
        await _customerName(handle.database, 'customer-1'),
        'Server confirmed',
      );
    });

    test('Customer without pending mutation accepts remote projection',
        () async {
      await _seedCustomer(handle.database);

      await SyncProjectionApplier.applyChange(
        handle.database,
        _remoteCustomerChange('Remote current'),
      );

      expect(
          await _customerName(handle.database, 'customer-1'), 'Remote current');
    });

    test('Sync transports UPDATE, confirms Outbox and releases convergence',
        () async {
      await _seedCustomer(handle.database);
      await _activateSyncV2(handle.database);
      final container = _container(sessionKey);
      addTearDown(container.dispose);
      await container.read(customersProvider.future);
      await container.read(customersProvider.notifier).updateCustomer(
            id: 'customer-1',
            name: 'Local transported',
            email: 'transported@example.test',
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
      expect(entry['entityType'], 'CUSTOMER');
      expect(entry['entityId'], 'customer-1');
      expect(entry['operationType'], 'UPDATE');
      expect(entry['payload'], {
        'name': 'Local transported',
        'document': null,
        'email': 'transported@example.test',
        'phone': null,
        'address': null,
      });
      expect(
        (await handle.database.query('outbox')).single['status'],
        'SYNCED',
      );

      await SyncProjectionApplier.applyChange(
        handle.database,
        _remoteCustomerChange('Server converged'),
      );
      expect(
        await _customerName(handle.database, 'customer-1'),
        'Server converged',
      );
    });
  });

  group('FE03-P07-B session and tenant isolation', () {
    test('logout during update cannot publish stale result', () async {
      await _seedCustomer(handle.database);
      final entered = Completer<void>();
      final release = Completer<void>();
      final repository = _BlockingCustomerRepository(
        CustomerLocalDataSource(),
        entered,
        release,
      );
      final container = _controlledContainer(
        sessionKey,
        repository: repository,
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        customersProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(customersProvider.future);

      final update = container
          .read(customersProvider.notifier)
          .updateCustomer(id: 'customer-1', name: 'Committed only to A');
      await entered.future;
      container.read(_controlledSessionKey.notifier).state = null;
      release.complete();

      await expectLater(update, throwsA(anything));
      expect(
        await _customerName(handle.database, 'customer-1'),
        'Committed only to A',
      );
      expect((await handle.database.query('outbox')).length, 1);
    });

    test('user and organization switch never writes Customer into tenant B',
        () async {
      await _seedCustomer(handle.database);
      final dbA = handle.database;
      final entered = Completer<void>();
      final release = Completer<void>();
      final container = _controlledContainer(
        sessionKey,
        repository: _BlockingCustomerRepository(
          CustomerLocalDataSource(),
          entered,
          release,
        ),
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        customersProvider,
        (_, __) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      await container.read(customersProvider.future);

      final update = container
          .read(customersProvider.notifier)
          .updateCustomer(id: 'customer-1', name: 'Tenant A only');
      await entered.future;
      final keyB = AuthenticatedSessionKey(
        scope: _scopeB,
        sessionGeneration: sessionGeneration + 1,
      );
      container.read(_controlledSessionKey.notifier).state = keyB;
      release.complete();
      await expectLater(update, throwsA(anything));

      expect(await _customerName(dbA, 'customer-1'), 'Tenant A only');
      expect((await dbA.query('outbox')).length, 1);

      handle = await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        _scopeB,
        sessionGeneration: ++sessionGeneration,
      );
      expect(await handle.database.query('customers'), isEmpty);
      expect(await handle.database.query('outbox'), isEmpty);
    });
  });

  testWidgets('Customer UI edits all supported fields', (tester) async {
    final notifier = _RecordingCustomersNotifier();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          customersProvider.overrideWith(() => notifier),
        ],
        child: const MaterialApp(home: CustomersPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Editar'));
    await tester.pumpAndSettle();

    expect(find.text('Editar Cliente'), findsOneWidget);
    final fields = find.byType(TextFormField);
    expect(fields, findsNWidgets(5));
    await tester.enterText(fields.at(0), 'Nome Editado');
    await tester.enterText(fields.at(1), 'DOC-2');
    await tester.enterText(fields.at(2), 'editado@example.test');
    await tester.enterText(fields.at(3), '11999990000');
    await tester.enterText(fields.at(4), 'Rua Nova');
    await tester.tap(find.text('Salvar').last);
    await tester.pumpAndSettle();

    expect(notifier.updateCalls, 1);
    expect(notifier.updatedId, 'customer-1');
    expect(notifier.updatedName, 'Nome Editado');
    expect(notifier.updatedDocument, 'DOC-2');
    expect(notifier.updatedEmail, 'editado@example.test');
    expect(notifier.updatedPhone, '11999990000');
    expect(notifier.updatedAddress, 'Rua Nova');
  });
}

ProviderContainer _container(
  AuthenticatedSessionKey key, {
  CustomerRepository? repository,
  OutboxDao? outboxDao,
}) {
  return ProviderContainer(
    overrides: [
      authenticatedSessionKeyProvider.overrideWithValue(key),
      isOnlineSessionProvider.overrideWithValue(false),
      if (repository != null)
        customerRepositoryProvider.overrideWithValue(repository),
      if (outboxDao != null) outboxDaoProvider.overrideWithValue(outboxDao),
    ],
  );
}

ProviderContainer _controlledContainer(
  AuthenticatedSessionKey key, {
  required CustomerRepository repository,
}) {
  return ProviderContainer(
    overrides: [
      _controlledSessionKey.overrideWith((ref) => key),
      authenticatedSessionKeyProvider.overrideWith(
        (ref) => ref.watch(_controlledSessionKey),
      ),
      isOnlineSessionProvider.overrideWithValue(false),
      customerRepositoryProvider.overrideWithValue(repository),
    ],
  );
}

Future<void> _seedCustomer(Database db) {
  return CustomerLocalDataSource().upsert(
    CustomerEntity(
      id: 'customer-1',
      name: 'Original',
      document: 'DOC-1',
      email: 'original@example.test',
      phone: '1100000000',
      address: 'Rua Antiga',
      updatedAt: '2026-09-23T10:00:00.000Z',
    ),
    executor: db,
  );
}

Future<String?> _customerName(Database db, String id) async {
  final rows = await db.query(
    'customers',
    columns: ['name'],
    where: 'id = ?',
    whereArgs: [id],
  );
  return rows.isEmpty ? null : rows.single['name'] as String;
}

Map<String, dynamic> _remoteCustomerChange(String name) => {
      'entityType': 'CUSTOMER',
      'entityId': 'customer-1',
      'operationType': 'UPDATE',
      'data': {
        'contractVersion': 2,
        'projectionRevision': '2',
        'id': 'customer-1',
        'name': name,
        'document': null,
        'email': null,
        'phone': null,
        'address': null,
        'updatedAt': '2026-09-23T14:00:00.000Z',
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

final class _ThrowingCustomerRepository implements CustomerRepository {
  _ThrowingCustomerRepository(this.delegate);

  final CustomerRepository delegate;

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) =>
      delegate.delete(id, executor: executor);

  @override
  Future<CustomerEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) =>
      delegate.findById(id, executor: executor);

  @override
  Future<List<CustomerEntity>> listAll({DatabaseExecutor? executor}) =>
      delegate.listAll(executor: executor);

  @override
  Future<void> upsert(
    CustomerEntity customer, {
    DatabaseExecutor? executor,
  }) {
    throw StateError('Simulated repository failure.');
  }
}

final class _BlockingCustomerRepository implements CustomerRepository {
  _BlockingCustomerRepository(this.delegate, this.entered, this.release);

  final CustomerRepository delegate;
  final Completer<void> entered;
  final Completer<void> release;

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) =>
      delegate.delete(id, executor: executor);

  @override
  Future<CustomerEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) =>
      delegate.findById(id, executor: executor);

  @override
  Future<List<CustomerEntity>> listAll({DatabaseExecutor? executor}) =>
      delegate.listAll(executor: executor);

  @override
  Future<void> upsert(
    CustomerEntity customer, {
    DatabaseExecutor? executor,
  }) async {
    await delegate.upsert(customer, executor: executor);
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

final class _RecordingCustomersNotifier extends CustomersNotifier {
  int updateCalls = 0;
  String? updatedId;
  String? updatedName;
  String? updatedDocument;
  String? updatedEmail;
  String? updatedPhone;
  String? updatedAddress;

  @override
  Future<List<CustomerEntity>> build() async => [
        CustomerEntity(
          id: 'customer-1',
          name: 'Original',
          document: 'DOC-1',
          email: 'original@example.test',
          phone: '1100000000',
          address: 'Rua Antiga',
          updatedAt: '2026-09-23T10:00:00.000Z',
        ),
      ];

  @override
  Future<void> updateCustomer({
    required String id,
    required String name,
    String? document,
    String? email,
    String? phone,
    String? address,
  }) async {
    updateCalls++;
    updatedId = id;
    updatedName = name;
    updatedDocument = document;
    updatedEmail = email;
    updatedPhone = phone;
    updatedAddress = address;
  }
}
