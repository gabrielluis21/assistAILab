import 'dart:convert';
import '../../../core/network/api_client.dart';

class OnboardingRemoteDataSource {
  final ApiClient apiClient;

  OnboardingRemoteDataSource(this.apiClient);

  Future<String> generateOnboardingToken(String serviceOrderId) async {
    final response = await apiClient.post(
      '/auth/customer-onboarding/service-orders/$serviceOrderId/grant',
    );

    if (response.statusCode == 201 || response.statusCode == 200) {
      final body = jsonDecode(response.body);
      return body['token'];
    } else {
      throw Exception('Failed to generate token: ${response.body}');
    }
  }

  Future<void> claimOnboardingToken(String token) async {
    final response = await apiClient.post(
      '/auth/customer-onboarding/claim',
      body: {'token': token},
    );

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('Failed to claim token: ${response.body}');
    }
  }
}
