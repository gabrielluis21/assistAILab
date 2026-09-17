import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'part_entity.dart';
import 'part_repository.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../auth/application/auth_provider.dart';
import '../auth/domain/entities/session_state.dart';
import '../../core/money/money_minor.dart';

typedef _SessionDatabaseBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

final partRepositoryProvider = Provider<PartRepository>(
  (ref) => PartLocalDataSource(),
);

class PartsNotifier extends AutoDisposeAsyncNotifier<List<PartEntity>> {
  @override
  Future<List<PartEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    return _load(binding);
  }

  Future<List<PartEntity>> _load(
    _SessionDatabaseBinding binding,
  ) async {
    final repo = ref.read(partRepositoryProvider);
    final parts = await repo.listAll(
      executor: binding.databaseHandle.database,
    );
    _ensureBindingCurrent(binding);
    return parts;
  }

  Future<void> createPart({
    required String name,
    required String sku,
    required MoneyMinor price,
    required MoneyMinor costPrice,
    required int stockQuantity,
  }) async {
    throw UnsupportedError(
      'PART_TENANCY_REQUIRED: Backend PART writes are not available.',
    );
  }

  Future<void> deletePart(String id) async {
    throw UnsupportedError(
      'PART_TENANCY_REQUIRED: Backend PART writes are not available.',
    );
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    final parts = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(parts);
  }

  _SessionDatabaseBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError('An authenticated session is required for parts.');
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated parts session.',
      );
    }

    return (
      sessionKey: sessionKey,
      databaseHandle: handle,
    );
  }

  bool _isBindingCurrent(_SessionDatabaseBinding binding) {
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        AuthScopedDatabaseManager.instance
            .isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_SessionDatabaseBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError('The parts operation belongs to a stale session.');
    }
  }
}

final partsProvider =
    AutoDisposeAsyncNotifierProvider<PartsNotifier, List<PartEntity>>(
  PartsNotifier.new,
);
