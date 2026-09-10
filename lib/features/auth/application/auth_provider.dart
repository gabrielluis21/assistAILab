import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/entities/user.dart';
import '../domain/entities/auth_scope.dart';
import '../domain/services/auth_scope_manager.dart';
import '../../../core/database/auth_scoped_database_manager.dart';
import '../domain/repositories/auth_repository.dart';
import '../data/repositories/auth_repository_impl.dart';
import '../data/datasources/auth_remote_datasource.dart';
import '../../../../core/network/api_client.dart';

final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient();
});

final authRemoteDataSourceProvider = Provider<AuthRemoteDataSource>((ref) {
  final apiClient = ref.read(apiClientProvider);
  return AuthRemoteDataSource(apiClient);
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final remoteDataSource = ref.read(authRemoteDataSourceProvider);
  return AuthRepositoryImpl(remoteDataSource);
});

final authStateProvider =
    StateNotifierProvider<AuthNotifier, AsyncValue<User?>>((ref) {
  final repository = ref.read(authRepositoryProvider);
  return AuthNotifier(repository);
});

final authScopeProvider = Provider<AuthScope?>((ref) {
  final userAsync = ref.watch(authStateProvider);
  return userAsync.when(
    data: (user) => AuthScopeManager.scopeFromUser(user),
    loading: () => null,
    error: (_, __) => null,
  );
});

class AuthNotifier extends StateNotifier<AsyncValue<User?>> {
  final AuthRepository _repository;

  AuthNotifier(this._repository) : super(const AsyncValue.loading()) {
    _loadUser();
  }

  Future<void> _loadUser() async {
    try {
      final user = await _repository.getCurrentUser();
      state = AsyncValue.data(user);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> login(String email, String password) async {
    state = const AsyncValue.loading();
    try {
      final user = await _repository.login(email, password);
      state = AsyncValue.data(user);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> logout() async {
    state = const AsyncValue.loading();
    try {
      await _repository.logout();
      // Ensure any scoped SQLite database is closed on logout to prevent stale handles.
      await AuthScopedDatabaseManager.instance.closeCurrentDatabase();
      state = const AsyncValue.data(null);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

}
