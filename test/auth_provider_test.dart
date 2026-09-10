import 'dart:convert';

import 'package:assistailab/core/network/api_client.dart';
import 'package:assistailab/core/security/credential_storage.dart';
import 'package:assistailab/features/auth/data/datasources/auth_remote_datasource.dart';
import 'package:assistailab/features/auth/data/repositories/auth_repository_impl.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _meResponse =
    '{"user":{"id":"u1","name":"Test User","email":"test@example.com",'
    '"role":"TECHNICIAN","status":"ACTIVE","customerId":null,'
    '"organizationId":"org-123"}}';

void main() {
  group('User', () {
    test('round-trips required and scoped fields', () {
      const user = User(
        id: '1',
        name: 'Test User',
        email: 'test@example.com',
        role: 'TECHNICIAN',
        status: 'ACTIVE',
        organizationId: 'org-100',
      );

      final restored = User.fromJson(user.toJson());

      expect(restored.id, '1');
      expect(restored.email, 'test@example.com');
      expect(restored.organizationId, 'org-100');
    });

    test('rejects a non-string required field', () {
      expect(
        () => User.fromJson(<String, dynamic>{
          'id': 1,
          'name': 'Test User',
          'email': 'test@example.com',
          'role': 'TECHNICIAN',
          'status': 'ACTIVE',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('AuthRemoteDataSource credential provenance', () {
    test('login is explicitly anonymous even when storage contains a token',
        () async {
      final storage = _RecordingCredentialStorage(
        StoredCredential(
          accessToken: 'residual-session-token',
          bindingId: 'old-binding',
        ),
      );
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          '{"token":"new-token","user":${jsonEncode(_userJson)}}',
          200,
        );
      });
      final dataSource = AuthRemoteDataSource(
        ApiClient(
          baseUrl: 'https://api.example.test',
          client: client,
          credentialStorage: storage,
        ),
      );

      await dataSource.login('test@example.com', 'secret');

      expect(captured.method, 'POST');
      expect(captured.url.path, '/auth/login');
      expect(captured.headers, isNot(contains('authorization')));
      expect(storage.readCalls, 0);
      expect(jsonDecode(captured.body), <String, dynamic>{
        'email': 'test@example.com',
        'password': 'secret',
      });
    });

    test('/auth/me uses the exact captured token, never the stored token',
        () async {
      final storage = _RecordingCredentialStorage(
        StoredCredential(
          accessToken: 'different-current-token',
          bindingId: 'current-binding',
        ),
      );
      late http.Request captured;
      final dataSource = AuthRemoteDataSource(
        ApiClient(
          baseUrl: 'https://api.example.test',
          client: MockClient((request) async {
            captured = request;
            return http.Response(_meResponse, 200);
          }),
          credentialStorage: storage,
        ),
      );

      final result = await dataSource.getMe('captured-bootstrap-token');

      expect((result['user'] as Map<String, dynamic>)['id'], 'u1');
      expect(captured.method, 'GET');
      expect(captured.url.path, '/auth/me');
      expect(
        captured.headers['authorization'],
        'Bearer captured-bootstrap-token',
      );
      expect(storage.readCalls, 0);
    });

    for (final statusCode in <int>[401, 403]) {
      test('/auth/me maps HTTP $statusCode to UnauthorizedException', () async {
        final dataSource = _dataSourceReturning(
          statusCode,
          '{"error":"rejected"}',
        );

        await expectLater(
          dataSource.getMe('captured-token'),
          throwsA(
            isA<UnauthorizedException>().having(
              (error) => error.statusCode,
              'statusCode',
              statusCode,
            ),
          ),
        );
      });
    }

    test('/auth/me exposes typed server-unavailable failure', () async {
      final dataSource = _dataSourceReturning(
        503,
        '{"error":"unavailable"}',
      );

      await expectLater(
        dataSource.getMe('captured-token'),
        throwsA(
          isA<AuthRemoteException>()
              .having((error) => error.statusCode, 'statusCode', 503)
              .having(
                (error) => error.isServerUnavailable,
                'isServerUnavailable',
                isTrue,
              ),
        ),
      );
    });

    test('malformed success payload fails as AuthResponseFormatException',
        () async {
      final dataSource = _dataSourceReturning(200, 'not-json');

      await expectLater(
        dataSource.getMe('captured-token'),
        throwsA(isA<AuthResponseFormatException>()),
      );
    });
  });

  group('AuthRepositoryImpl', () {
    test('parses the authoritative /auth/me user', () async {
      final repository = AuthRepositoryImpl(
        _dataSourceReturning(200, _meResponse),
      );

      final user = await repository.getCurrentUser('exact-token');

      expect(user.id, 'u1');
      expect(user.role, 'TECHNICIAN');
      expect(user.organizationId, 'org-123');
    });

    test('rejects login response without a non-empty token', () async {
      final repository = AuthRepositoryImpl(
        _dataSourceReturning(
          200,
          '{"token":"","user":${jsonEncode(_userJson)}}',
        ),
      );

      await expectLater(
        repository.login('test@example.com', 'secret'),
        throwsA(isA<AuthResponseFormatException>()),
      );
    });
  });
}

const Map<String, dynamic> _userJson = <String, dynamic>{
  'id': 'u1',
  'name': 'Test User',
  'email': 'test@example.com',
  'role': 'TECHNICIAN',
  'status': 'ACTIVE',
  'customerId': null,
  'organizationId': 'org-123',
};

AuthRemoteDataSource _dataSourceReturning(int statusCode, String body) {
  return AuthRemoteDataSource(
    ApiClient(
      baseUrl: 'https://api.example.test',
      client: MockClient((_) async => http.Response(body, statusCode)),
      credentialStorage: _RecordingCredentialStorage(),
    ),
  );
}

final class _RecordingCredentialStorage implements CredentialStorage {
  _RecordingCredentialStorage([this.value]);

  StoredCredential? value;
  String? cleanupPendingBindingId;
  int readCalls = 0;

  @override
  Future<StoredCredential?> read() async {
    readCalls++;
    return value;
  }

  @override
  Future<void> write(StoredCredential credential) async {
    value = credential;
  }

  @override
  Future<String?> readCleanupPendingBindingId() async =>
      cleanupPendingBindingId;

  @override
  Future<void> markCleanupPending(String bindingId) async {
    cleanupPendingBindingId = bindingId;
  }

  @override
  Future<void> delete() async {
    value = null;
  }

  @override
  Future<bool> deleteIfMatches(String bindingId) async {
    if (value?.bindingId != bindingId) return false;
    value = null;
    return true;
  }

  @override
  Future<void> clearCleanupPending(String bindingId) async {
    if (cleanupPendingBindingId == bindingId) {
      cleanupPendingBindingId = null;
    }
  }

  @override
  Future<void> purgeLegacyCredentials() async {}
}
