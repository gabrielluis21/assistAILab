import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/sync/sync_providers.dart';
import '../auth/application/auth_provider.dart';
import '../auth/domain/entities/auth_scope.dart';
import '../auth/domain/entities/session_state.dart';
import 'equipment_entity.dart';
import 'equipments_provider.dart';
import 'pre_acquisition_entity.dart';
import 'pre_acquisition_repository.dart';

typedef _PreAcquisitionBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
  String organizationId,
});

final preAcquisitionRepositoryProvider = Provider<PreAcquisitionRepository>(
  (ref) => PreAcquisitionLocalDataSource(),
);

class PreAcquisitionsNotifier
    extends AutoDisposeAsyncNotifier<List<PreAcquisitionEntity>> {
  @override
  Future<List<PreAcquisitionEntity>> build() async {
    final binding = _captureBinding(
      ref.watch(authenticatedSessionKeyProvider),
    );
    return _load(binding);
  }

  Future<List<PreAcquisitionEntity>> _load(
    _PreAcquisitionBinding binding,
  ) async {
    final records = await ref.read(preAcquisitionRepositoryProvider).listAll(
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
    if (records.any(
      (record) => record.organizationId != binding.organizationId,
    )) {
      throw StateError(
        'PreAcquisition data crossed the authenticated organization scope.',
      );
    }
    return records;
  }

  Future<void> createPreAcquisition({
    required String equipmentId,
    String? serviceOrderId,
    int? offeredAmountMinor,
    String? notes,
    required DateTime evaluationDeadline,
  }) async {
    if (offeredAmountMinor != null && offeredAmountMinor < 0) {
      throw ArgumentError.value(
        offeredAmountMinor,
        'offeredAmountMinor',
        'Must be zero or greater.',
      );
    }
    final normalizedServiceOrderId = _optionalText(serviceOrderId);
    final normalizedNotes = _optionalText(notes);
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final repository = ref.read(preAcquisitionRepositoryProvider);
    final equipmentRepository = ref.read(equipmentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);
    const uuid = Uuid();

    await binding.databaseHandle.database.transaction((txn) async {
      final equipment = await equipmentRepository.findById(
        equipmentId,
        executor: txn,
      );
      _assertEligibleEquipment(equipment);
      final eligibleEquipment = equipment!;

      final createdAt = DateTime.now().toUtc().toIso8601String();
      final preAcquisition = PreAcquisitionEntity(
        id: uuid.v4(),
        equipmentId: eligibleEquipment.id,
        customerId: eligibleEquipment.customerId!,
        organizationId: binding.organizationId,
        serviceOrderId: normalizedServiceOrderId,
        status: PreAcquisitionStatus.pendingEvaluation,
        offeredAmountMinor: offeredAmountMinor,
        notes: normalizedNotes,
        createdAt: createdAt,
        evaluationDeadline: evaluationDeadline.toUtc().toIso8601String(),
      );

      await repository.insert(preAcquisition, executor: txn);
      await outbox.insert(
        OutboxItem(
          operationId: uuid.v4(),
          entityType: 'PRE_ACQUISITION',
          entityId: preAcquisition.id,
          operationType: 'CREATE',
          payload: preAcquisition.toOutboxPayload(),
          createdAt: createdAt,
          status: 'REQUIRES_ATTENTION',
        ),
        executor: txn,
      );
    });

    await _publishCurrent(binding);
  }

  Future<void> resolvePreAcquisition({
    required String id,
    required PreAcquisitionStatus status,
    String? resolutionReason,
  }) async {
    if (!status.isTerminal) {
      throw ArgumentError.value(
        status,
        'status',
        'Resolution must use a terminal status.',
      );
    }
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    final repository = ref.read(preAcquisitionRepositoryProvider);
    final equipmentRepository = ref.read(equipmentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await binding.databaseHandle.database.transaction((txn) async {
      final existing = await repository.findById(id, executor: txn);
      if (existing == null ||
          existing.organizationId != binding.organizationId) {
        throw StateError(
          'PreAcquisition is not available in the authenticated scope.',
        );
      }
      if (existing.status != PreAcquisitionStatus.pendingEvaluation) {
        throw StateError('PreAcquisition is already resolved.');
      }
      final equipment = await equipmentRepository.findById(
        existing.equipmentId,
        executor: txn,
      );
      _assertEligibleEquipment(equipment);
      final eligibleEquipment = equipment!;
      if (eligibleEquipment.customerId != existing.customerId) {
        throw StateError(
          'PreAcquisition Customer no longer matches the Equipment.',
        );
      }

      final evaluatedAt = DateTime.now().toUtc().toIso8601String();
      final resolved = PreAcquisitionEntity(
        id: existing.id,
        equipmentId: existing.equipmentId,
        customerId: existing.customerId,
        organizationId: existing.organizationId,
        serviceOrderId: existing.serviceOrderId,
        status: status,
        offeredAmountMinor: existing.offeredAmountMinor,
        notes: existing.notes,
        createdAt: existing.createdAt,
        evaluationDeadline: existing.evaluationDeadline,
        evaluatedAt: evaluatedAt,
        resolutionReason: _optionalText(resolutionReason),
      );

      await repository.update(resolved, executor: txn);
      await outbox.insert(
        OutboxItem(
          operationId: const Uuid().v4(),
          entityType: 'PRE_ACQUISITION',
          entityId: resolved.id,
          operationType: 'UPDATE',
          payload: resolved.toOutboxPayload(),
          createdAt: evaluatedAt,
          status: 'REQUIRES_ATTENTION',
        ),
        executor: txn,
      );
    });

    await _publishCurrent(binding);
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    state = AsyncData(await _load(binding));
  }

  Future<void> _publishCurrent(_PreAcquisitionBinding binding) async {
    _ensureBindingCurrent(binding);
    final records = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(records);
  }

  _PreAcquisitionBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError(
        'An authenticated professional session is required.',
      );
    }
    final scope = sessionKey.scope;
    if (scope is! ProfessionalAuthScope) {
      throw StateError(
        'PreAcquisition is restricted to a professional organization scope.',
      );
    }

    final manager = AuthScopedDatabaseManager.instance;
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the PreAcquisition session.',
      );
    }

    return (
      sessionKey: sessionKey,
      databaseHandle: handle,
      organizationId: scope.organizationId,
    );
  }

  bool _isBindingCurrent(_PreAcquisitionBinding binding) {
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        AuthScopedDatabaseManager.instance
            .isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_PreAcquisitionBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError(
        'The PreAcquisition operation belongs to a stale session.',
      );
    }
  }
}

final preAcquisitionsProvider = AutoDisposeAsyncNotifierProvider<
    PreAcquisitionsNotifier, List<PreAcquisitionEntity>>(
  PreAcquisitionsNotifier.new,
);

void _assertEligibleEquipment(EquipmentEntity? equipment) {
  if (equipment == null) {
    throw StateError(
      'Equipment is not available in the authenticated scope.',
    );
  }
  if (equipment.ownerType != EquipmentOwnerType.customer ||
      equipment.customerId == null) {
    throw StateError(
      'PreAcquisition requires CUSTOMER-owned Equipment.',
    );
  }
}

String? _optionalText(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? null : normalized;
}
