import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/database/scope_hash_generator.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:assistailab/core/database/outbox_dao.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/network/api_client.dart';

class _FakeApiClient extends ApiClient {
  _FakeApiClient() : super(baseUrl: 'http://fake.api');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var sessionGeneration = 0;
  int nextSessionGeneration() => ++sessionGeneration;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (methodCall) async {
        return Directory.systemTemp.path;
      },
    );
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async {
    await AuthScopedDatabaseManager.instance.closeCurrentDatabase(
      sessionGeneration: nextSessionGeneration(),
    );
  });

  group('AuthScoped Database Foundation Tests (FE-01B)', () {
    const scopeProfA =
        ProfessionalAuthScope(userId: 'u1', organizationId: 'orgA');
    const scopeProfA2 =
        ProfessionalAuthScope(userId: 'u1', organizationId: 'orgA');
    const scopeProfB =
        ProfessionalAuthScope(userId: 'u1', organizationId: 'orgB');
    const scopeCustA = CustomerAuthScope(userId: 'u1', customerId: 'custA');

    // TEST A: same AuthScope → deterministic same DB identity/path
    test(
        'TEST A: same AuthScope yields deterministic same DB filename and hash',
        () {
      final name1 = ScopeHashGenerator.databaseFileName(scopeProfA);
      final name2 = ScopeHashGenerator.databaseFileName(scopeProfA2);
      expect(name1, equals(name2));
      expect(name1.startsWith('assistailab_'), isTrue);
      expect(name1.endsWith('.db'), isTrue);
    });

    // TEST B: different PROFESSIONAL organizations → different DB identity/path
    test(
        'TEST B: different PROFESSIONAL organizations yield different DB filename/path',
        () {
      final nameA = ScopeHashGenerator.databaseFileName(scopeProfA);
      final nameB = ScopeHashGenerator.databaseFileName(scopeProfB);
      expect(nameA, isNot(equals(nameB)));
    });

    // TEST C: same user PROFESSIONAL vs CUSTOMER → different DB identity/path
    test(
        'TEST C: same user PROFESSIONAL vs CUSTOMER yields different DB filename/path',
        () {
      final nameProf = ScopeHashGenerator.databaseFileName(scopeProfA);
      final nameCust = ScopeHashGenerator.databaseFileName(scopeCustA);
      expect(nameProf, isNot(equals(nameCust)));
    });

    // TEST D: InvalidAuthScope → DB open rejected / fail closed
    test('TEST D: InvalidAuthScope rejected when opening DB (fail closed)',
        () async {
      const invalidScope = InvalidAuthScope(
        userId: 'u1',
        role: 'ADMIN',
        reason: 'Missing organizationId',
      );

      expect(
        () async =>
            await AuthScopedDatabaseManager.instance.openDatabaseForScope(
          invalidScope,
          sessionGeneration: nextSessionGeneration(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(AuthScopedDatabaseManager.instance.hasActiveDatabase, isFalse);
    });

    // TEST E: null unauthenticated → authenticated scoped DB unavailable
    test('TEST E: null unauthenticated scope rejected when opening DB',
        () async {
      expect(
        () async =>
            await AuthScopedDatabaseManager.instance.openDatabaseForScope(
          null,
          sessionGeneration: nextSessionGeneration(),
        ),
        throwsA(isA<StateError>()),
      );
      expect(AuthScopedDatabaseManager.instance.hasActiveDatabase, isFalse);
      expect(
        () => SqliteDatabase.instance,
        throwsA(isA<StateError>()),
      );
    });

    // TEST F: Scope A cursor "100" vs Scope B cursor "900" isolation
    test('TEST F: Cursor isolation between Scope A and Scope B', () async {
      const scopeFA =
          ProfessionalAuthScope(userId: 'uF', organizationId: 'orgF_A');
      const scopeFB =
          ProfessionalAuthScope(userId: 'uF', organizationId: 'orgF_B');
      final syncEngine = SyncEngine(apiClient: _FakeApiClient());

      // Open Scope A
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeFA,
        sessionGeneration: nextSessionGeneration(),
      );
      await syncEngine.saveLocalCursor('100');
      expect(await syncEngine.getLocalCursor(), equals('100'));

      // Switch to Scope B
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeFB,
        sessionGeneration: nextSessionGeneration(),
      );
      await syncEngine.saveLocalCursor('900');
      expect(await syncEngine.getLocalCursor(), equals('900'));

      // Reactivate Scope A
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeFA,
        sessionGeneration: nextSessionGeneration(),
      );
      expect(await syncEngine.getLocalCursor(), equals('100'));
    });

    // TEST G: Scope A creates Outbox entry → Scope B cannot see it
    test('TEST G: Outbox isolation between Scope A and Scope B', () async {
      const scopeGA =
          ProfessionalAuthScope(userId: 'uG', organizationId: 'orgG_A');
      const scopeGB =
          ProfessionalAuthScope(userId: 'uG', organizationId: 'orgG_B');
      final outboxDao = OutboxDao();
      final itemA = OutboxItem(
        operationId: 'op-A-1',
        entityType: 'CUSTOMER',
        entityId: 'c1',
        operationType: 'CREATE',
        payload: {'name': 'Client A'},
        createdAt: DateTime.now().toIso8601String(),
      );

      // Open Scope A & insert entry
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeGA,
        sessionGeneration: nextSessionGeneration(),
      );
      await outboxDao.insert(itemA);
      final entriesA = await outboxDao.getPendingEntries();
      expect(entriesA.length, equals(1));
      expect(entriesA.first.operationId, equals('op-A-1'));

      // Switch to Scope B
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeGB,
        sessionGeneration: nextSessionGeneration(),
      );
      final entriesB = await outboxDao.getPendingEntries();
      expect(entriesB.isEmpty, isTrue);
    });

    // TEST H: Scope A logout → activate B → no live reference/reuse of A database
    test(
        'TEST H: Logout closes A and opening B does not reuse A connection/file',
        () async {
      const scopeHA =
          ProfessionalAuthScope(userId: 'uH', organizationId: 'orgH_A');
      const scopeHB =
          ProfessionalAuthScope(userId: 'uH', organizationId: 'orgH_B');

      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeHA,
        sessionGeneration: nextSessionGeneration(),
      );
      final fileA = AuthScopedDatabaseManager.instance.activeDbFileName;

      // Logout / clear active database
      await AuthScopedDatabaseManager.instance.closeCurrentDatabase(
        sessionGeneration: nextSessionGeneration(),
      );
      expect(AuthScopedDatabaseManager.instance.hasActiveDatabase, isFalse);

      // Activate Scope B
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeHB,
        sessionGeneration: nextSessionGeneration(),
      );
      final fileB = AuthScopedDatabaseManager.instance.activeDbFileName;

      expect(fileA, isNot(equals(fileB)));
    });

    // TEST I: reactivate A → A operational data remains available
    test('TEST I: Reactivate Scope A restores operational data intact',
        () async {
      const scopeIA =
          ProfessionalAuthScope(userId: 'uI', organizationId: 'orgI_A');
      const scopeIB =
          ProfessionalAuthScope(userId: 'uI', organizationId: 'orgI_B');
      final outboxDao = OutboxDao();
      final itemA = OutboxItem(
        operationId: 'op-A-persist',
        entityType: 'CUSTOMER',
        entityId: 'c-persist',
        operationType: 'CREATE',
        payload: {'name': 'Persistent Client'},
        createdAt: DateTime.now().toIso8601String(),
      );

      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeIA,
        sessionGeneration: nextSessionGeneration(),
      );
      await outboxDao.insert(itemA);

      // Switch away to Scope B
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeIB,
        sessionGeneration: nextSessionGeneration(),
      );

      // Switch back to Scope A
      await AuthScopedDatabaseManager.instance.openDatabaseForScope(
        scopeIA,
        sessionGeneration: nextSessionGeneration(),
      );
      final entries = await outboxDao.getPendingEntries();
      expect(entries.length, equals(1));
      expect(entries.first.operationId, equals('op-A-persist'));
    });

    // TEST J: legacy assistailab_local.db → never automatically selected for valid AuthScope
    test(
        'TEST J: Legacy assistailab_local.db filename is never selected for valid AuthScope',
        () {
      final filenameProf = ScopeHashGenerator.databaseFileName(scopeProfA);
      final filenameCust = ScopeHashGenerator.databaseFileName(scopeCustA);

      expect(filenameProf, isNot(equals('assistailab_local.db')));
      expect(filenameCust, isNot(equals('assistailab_local.db')));
    });

    // TEST K: Web → SQLite open remains rejected / not used
    test(
        'TEST K: ScopeHashGenerator throws on InvalidAuthScope and produces hashed filenames',
        () {
      const invalid = InvalidAuthScope(
          userId: 'u1', role: 'CUSTOMER', reason: 'no customerId');
      expect(
        () => ScopeHashGenerator.databaseFileName(invalid),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
