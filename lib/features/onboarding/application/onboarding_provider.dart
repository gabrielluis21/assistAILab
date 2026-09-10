import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/application/auth_provider.dart';
import '../../auth/application/session_api_client.dart';
import '../data/onboarding_remote_datasource.dart';

final onboardingDataSourceProvider =
    Provider<OnboardingRemoteDataSource>((ref) {
  final apiClient = ref.watch(sessionApiClientProvider);
  return OnboardingRemoteDataSource(apiClient);
});

final onboardingProvider =
    StateNotifierProvider<OnboardingNotifier, AsyncValue<String?>>((ref) {
  // Recreate/reset grant state for every authenticated session generation.
  ref.watch(authenticatedSessionKeyProvider);
  return OnboardingNotifier(ref.watch(onboardingDataSourceProvider));
});

class OnboardingNotifier extends StateNotifier<AsyncValue<String?>> {
  final OnboardingRemoteDataSource _dataSource;

  OnboardingNotifier(this._dataSource) : super(const AsyncValue.data(null));

  int _operationGeneration = 0;

  Future<void> generateToken(String serviceOrderId) async {
    final generation = ++_operationGeneration;
    state = const AsyncValue.loading();
    try {
      final token = await _dataSource.generateOnboardingToken(serviceOrderId);
      if (mounted && generation == _operationGeneration) {
        state = AsyncValue.data(token);
      }
    } catch (e, st) {
      if (mounted && generation == _operationGeneration) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  Future<void> claimToken(String token) async {
    final generation = ++_operationGeneration;
    state = const AsyncValue.loading();
    try {
      await _dataSource.claimOnboardingToken(token);
      if (mounted && generation == _operationGeneration) {
        state = const AsyncValue.data('CLAIM_SUCCESS');
      }
    } catch (e, st) {
      if (mounted && generation == _operationGeneration) {
        state = AsyncValue.error(e, st);
      }
    }
  }

  void reset() {
    _operationGeneration++;
    state = const AsyncValue.data(null);
  }
}
