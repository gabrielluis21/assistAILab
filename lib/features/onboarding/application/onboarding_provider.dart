import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../auth/application/auth_provider.dart';
import '../data/onboarding_remote_datasource.dart';

final onboardingDataSourceProvider = Provider<OnboardingRemoteDataSource>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return OnboardingRemoteDataSource(apiClient);
});

final onboardingProvider = StateNotifierProvider<OnboardingNotifier, AsyncValue<String?>>((ref) {
  return OnboardingNotifier(ref.watch(onboardingDataSourceProvider));
});

class OnboardingNotifier extends StateNotifier<AsyncValue<String?>> {
  final OnboardingRemoteDataSource _dataSource;

  OnboardingNotifier(this._dataSource) : super(const AsyncValue.data(null));

  Future<void> generateToken(String serviceOrderId) async {
    state = const AsyncValue.loading();
    try {
      final token = await _dataSource.generateOnboardingToken(serviceOrderId);
      state = AsyncValue.data(token);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> claimToken(String token) async {
    state = const AsyncValue.loading();
    try {
      await _dataSource.claimOnboardingToken(token);
      state = const AsyncValue.data('CLAIM_SUCCESS');
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  void reset() {
    state = const AsyncValue.data(null);
  }
}
