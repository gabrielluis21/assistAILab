import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/features/onboarding/application/onboarding_provider.dart';
import 'package:assistailab/features/onboarding/data/onboarding_remote_datasource.dart';
import 'package:assistailab/core/network/api_client.dart';

import 'package:http/http.dart' as http;

class FakeApiClient extends ApiClient {
  @override
  Future<http.Response> post(String endpoint, {Map<String, dynamic>? body}) async {
    if (endpoint.contains('grant')) {
      return http.Response('{"token": "fake_qr_token_123"}', 201);
    } else if (endpoint.contains('claim')) {
      return http.Response('{"status": "success"}', 200);
    }
    throw UnimplementedError();
  }
}


void main() {
  group('Onboarding Tests', () {
    test('generateToken updates state with token', () async {
      final fakeApiClient = FakeApiClient();
      final dataSource = OnboardingRemoteDataSource(fakeApiClient);
      final notifier = OnboardingNotifier(dataSource);

      expect(notifier.state.value, null);

      await notifier.generateToken('os_123');
      
      expect(notifier.state.value, 'fake_qr_token_123');
    });

    test('claimToken updates state to success', () async {
      final fakeApiClient = FakeApiClient();
      final dataSource = OnboardingRemoteDataSource(fakeApiClient);
      final notifier = OnboardingNotifier(dataSource);

      await notifier.claimToken('fake_qr_token_123');
      
      expect(notifier.state.value, 'CLAIM_SUCCESS');
    });
  });
}
