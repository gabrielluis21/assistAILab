import 'dart:async';
import 'dart:convert';

import 'package:assistailab/core/database/auth_scoped_database_manager.dart';
import 'package:assistailab/core/network/api_client.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/core/sync/sync_lease.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/application/session_api_client.dart';
import 'package:assistailab/features/auth/data/datasources/secure_session_stores.dart';
import 'package:assistailab/features/auth/domain/entities/offline_authority_record.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/auth/domain/repositories/auth_repository.dart';
import 'package:assistailab/features/auth/domain/repositories/offline_authority_store.dart';
import 'package:assistailab/features/auth/domain/repositories/user_profile_cache.dart';
import 'package:assistailab/features/auth/domain/services/session_security_validator.dart';
import 'package:assistailab/features/onboarding/application/onboarding_provider.dart';
import 'package:assistailab/features/onboarding/data/onboarding_remote_datasource.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

void main() {
  group('OnboardingNotifier session-aware requests', () {
    test('grant uses the exact current session credential and publishes token',
        () async {
      final harness = await _SessionHarness.create();
      final api = _RecordingApiClient();
      final notifier = OnboardingNotifier(
        OnboardingRemoteDataSource(
          SessionApiClient(apiClient: api, authNotifier: harness.auth),
        ),
      );

      await notifier.generateToken('os_123');

      expect(notifier.state.value, 'fake_qr_token_123');
      expect(api.boundCalls, 1);
      expect(api.unauthenticatedCalls, 0);
      expect(
        api.boundEndpoint,
        '/auth/customer-onboarding/service-orders/os_123/grant',
      );
      expect(api.boundCredential?.isExplicit, isTrue);
      expect(api.boundCredential?.pinnedToken, harness.accessToken);
      await harness.dispose();
    });

    test('claim remains explicitly anonymous during an authenticated session',
        () async {
      final harness = await _SessionHarness.create();
      final api = _RecordingApiClient();
      final notifier = OnboardingNotifier(
        OnboardingRemoteDataSource(
          SessionApiClient(apiClient: api, authNotifier: harness.auth),
        ),
      );

      await notifier.claimToken('fake_qr_token_123');

      expect(notifier.state.value, 'CLAIM_SUCCESS');
      expect(api.boundCalls, 0);
      expect(api.unauthenticatedCalls, 1);
      expect(api.unauthenticatedEndpoint, '/auth/customer-onboarding/claim');
      expect(api.unauthenticatedBody, <String, dynamic>{
        'token': 'fake_qr_token_123',
      });
      await harness.dispose();
    });

    test('reset invalidates an in-flight grant result deterministically',
        () async {
      final harness = await _SessionHarness.create();
      final entered = Completer<void>();
      final response = Completer<http.Response>();
      final api = _RecordingApiClient(
        onBoundPost: (_, __, ___) {
          entered.complete();
          return response.future;
        },
      );
      final notifier = OnboardingNotifier(
        OnboardingRemoteDataSource(
          SessionApiClient(apiClient: api, authNotifier: harness.auth),
        ),
      );

      final pending = notifier.generateToken('os_123');
      await entered.future;
      notifier.reset();
      response.complete(http.Response('{"token":"stale-token"}', 201));
      await pending;

      expect(notifier.state.value, isNull);
      await harness.dispose();
    });
  });
}

typedef _BoundPostHandler = Future<http.Response> Function(
  String endpoint,
  BoundCredential credential,
  Map<String, dynamic>? body,
);

final class _RecordingApiClient extends ApiClient {
  _RecordingApiClient({this.onBoundPost}) : super(baseUrl: 'http://fake.api');

  final _BoundPostHandler? onBoundPost;
  int boundCalls = 0;
  int unauthenticatedCalls = 0;
  String? boundEndpoint;
  BoundCredential? boundCredential;
  String? unauthenticatedEndpoint;
  Map<String, dynamic>? unauthenticatedBody;

  @override
  Future<http.Response> postBound(
    String endpoint,
    BoundCredential credential, {
    Map<String, dynamic>? body,
  }) async {
    boundCalls++;
    boundEndpoint = endpoint;
    boundCredential = credential;
    final handler = onBoundPost;
    if (handler != null) return handler(endpoint, credential, body);
    return http.Response('{"token":"fake_qr_token_123"}', 201);
  }

  @override
  Future<http.Response> postUnauthenticated(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    unauthenticatedCalls++;
    unauthenticatedEndpoint = endpoint;
    unauthenticatedBody = body;
    return http.Response('{"status":"success"}', 200);
  }
}

final class _SessionHarness {
  _SessionHarness._({
    required this.auth,
    required this.manager,
    required this.accessToken,
  });

  final AuthNotifier auth;
  final AuthScopedDatabaseManager manager;
  final String accessToken;

  static Future<_SessionHarness> create() async {
    final now = DateTime.utc(2026, 9, 10, 12);
    const user = User(
      id: 'technician-1',
      name: 'Technician',
      email: 'technician@example.com',
      role: 'TECHNICIAN',
      status: 'ACTIVE',
      organizationId: 'org-1',
    );
    final accessToken = _tokenFor(user, now);
    final manager = AuthScopedDatabaseManager.forTesting(
      opener: (_) async => _FakeDatabase(),
    );
    final auth = AuthNotifier(
      repository: _LoginRepository(user, accessToken),
      credentialStorage: _MemoryCredentialStorage(),
      profileCache: _MemoryProfileCache(),
      offlineAuthorityStore: _MemoryAuthorityStore(),
      credentialEpochStore: MemoryCredentialEpochStore(),
      secureVaultMetadataStore: MemorySecureVaultMetadataStore(),
      securityValidator: const SessionSecurityValidator(),
      databaseManager: manager,
      nowUtc: () => now,
      credentialBindingIdFactory: () => 'binding-1',
      credentialIdFactory: () => 'credential-1',
      autoBootstrap: false,
    );
    expect(await auth.login(user.email, 'secret'), isTrue);
    return _SessionHarness._(
      auth: auth,
      manager: manager,
      accessToken: accessToken,
    );
  }

  Future<void> dispose() async {
    final closeGeneration = auth.currentGeneration + 1000;
    auth.dispose();
    await manager.closeCurrentDatabase(
      sessionGeneration: closeGeneration,
    );
  }
}

String _tokenFor(User user, DateTime now) {
  String encode(Map<String, Object?> value) =>
      base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

  return '${encode(<String, Object?>{'alg': 'HS256', 'typ': 'JWT'})}.'
      '${encode(<String, Object?>{
        'sub': user.id,
        'role': user.role,
        'customerId': user.customerId,
        'organizationId': user.organizationId,
        'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
      })}.signature';
}

final class _LoginRepository implements AuthRepository {
  const _LoginRepository(this.user, this.accessToken);

  final User user;
  final String accessToken;

  @override
  Future<AuthLoginResult> login(String email, String password) async {
    return AuthLoginResult(user: user, accessToken: accessToken);
  }

  @override
  Future<User> getCurrentUser(String accessToken) async => user;
}

final class _MemoryCredentialStorage implements CredentialStorage {
  StoredCredential? value;

  @override
  Future<StoredCredential?> readById(String credentialId) async =>
      value?.credentialId == credentialId ? value : null;

  @override
  Future<void> write(StoredCredential credential) async {
    value = credential;
  }

  @override
  Future<void> deleteById(String credentialId) async {
    if (value?.credentialId == credentialId) value = null;
  }

  @override
  Future<bool> deleteIfMatches({
    required String credentialId,
    required int credentialGeneration,
  }) async {
    if (value?.credentialId != credentialId ||
        value?.credentialGeneration != credentialGeneration) {
      return false;
    }
    value = null;
    return true;
  }

  @override
  Future<void> purgeLegacyCredentials() async {}
}

final class _MemoryProfileCache implements UserProfileCache {
  User? value;

  @override
  Future<User?> read() async => value;

  @override
  Future<void> write(User user) async {
    value = user;
  }

  @override
  Future<void> delete() async {
    value = null;
  }
}

final class _MemoryAuthorityStore implements OfflineAuthorityStore {
  OfflineAuthorityRecord? value;

  @override
  Future<OfflineAuthorityRecord?> readByCredentialId(
          String credentialId) async =>
      value?.credentialId == credentialId ? value : null;

  @override
  Future<void> write(OfflineAuthorityRecord record) async {
    value = record;
  }

  @override
  Future<void> deleteByCredentialId(String credentialId) async {
    if (value?.credentialId == credentialId) value = null;
  }
}

final class _FakeDatabase implements Database {
  bool _isOpen = true;

  @override
  bool get isOpen => _isOpen;

  @override
  Future<void> close() async {
    _isOpen = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
