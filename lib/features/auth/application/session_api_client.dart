import 'package:http/http.dart' as http;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/sync/sync_lease.dart';
import 'auth_provider.dart';

final sessionApiClientProvider = Provider<SessionApiClient>((ref) {
  return SessionApiClient(
    apiClient: ref.watch(apiClientProvider),
    authNotifier: ref.read(authStateProvider.notifier),
  );
});

/// Executes ordinary authenticated resource requests with a credential and
/// session generation captured together.
///
/// Authorization failures are reported back with that exact generation, so a
/// late response from session A cannot terminate session B.
final class SessionApiClient {
  const SessionApiClient({
    required ApiClient apiClient,
    required AuthNotifier authNotifier,
  })  : _apiClient = apiClient,
        _authNotifier = authNotifier;

  final ApiClient _apiClient;
  final AuthNotifier _authNotifier;

  Future<http.Response> post(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final request = await _authNotifier.acquireOnlineRequestCredential();
    final response = await _apiClient.postBound(
      endpoint,
      BoundCredential.explicit(request.accessToken),
      body: body,
    );
    await _authNotifier.handleAuthorizationFailure(
      sessionGeneration: request.sessionGeneration,
      statusCode: response.statusCode,
      authorityRevalidation: false,
    );
    if (!_authNotifier.isGenerationCurrent(request.sessionGeneration)) {
      throw const SessionRequestBlockedException(
        'Request completed after its session was invalidated.',
      );
    }
    return response;
  }

  Future<http.Response> postUnauthenticated(
    String endpoint, {
    Map<String, dynamic>? body,
  }) {
    return _apiClient.postUnauthenticated(endpoint, body: body);
  }
}
