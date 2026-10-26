import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/commands/command_intent.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/database/outbox_dao.dart';
import '../../core/database/service_order_repository.dart';
import '../../core/sync/sync_providers.dart';
import '../auth/application/auth_provider.dart';
import '../auth/application/session_api_client.dart';
import '../auth/domain/entities/auth_scope.dart';
import '../auth/domain/entities/session_state.dart';
import '../service_orders/service_order_entity.dart';
import 'equipment_acquisition_command_executor.dart';
import 'equipment_acquisition_entity.dart';
import 'equipment_acquisition_gateway.dart';
import 'equipment_acquisition_repository.dart';
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
    ServiceOrderEntity? serviceOrder,
    required PreAcquisitionPurpose purpose,
    int? offeredAmountMinor,
    String? notes,
    required DateTime evaluationDeadline,
  }) async {
    if (offeredAmountMinor != null &&
        (offeredAmountMinor < 1 || offeredAmountMinor > 9999999999)) {
      throw ArgumentError.value(
        offeredAmountMinor,
        'offeredAmountMinor',
        'Must be between 1 and 9999999999.',
      );
    }
    if (serviceOrder != null &&
        !Uuid.isValidUUID(fromString: serviceOrder.id)) {
      throw ArgumentError.value(
        serviceOrder.id,
        'serviceOrder.id',
        'Must be an existing ServiceOrder UUID.',
      );
    }
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
      if (serviceOrder != null) {
        final persistedOrder = await ref
            .read(equipmentAcquisitionServiceOrderRepositoryProvider)
            .findById(serviceOrder.id, executor: txn);
        if (persistedOrder == null ||
            persistedOrder.equipmentId != eligibleEquipment.id ||
            persistedOrder.customerId != eligibleEquipment.customerId) {
          throw StateError(
            'Selected ServiceOrder does not match the Equipment and Customer.',
          );
        }
      }

      final createdAt = DateTime.now().toUtc().toIso8601String();
      final preAcquisition = PreAcquisitionEntity(
        id: uuid.v4(),
        equipmentId: eligibleEquipment.id,
        customerId: eligibleEquipment.customerId!,
        organizationId: binding.organizationId,
        serviceOrderId: serviceOrder?.id,
        purpose: purpose,
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
    if (status == PreAcquisitionStatus.pendingEvaluation) {
      throw ArgumentError.value(
        status,
        'status',
        'Resolution must leave PENDING_EVALUATION.',
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
        purpose: existing.purpose,
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

typedef _EquipmentAcquisitionBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
  AuthScope scope,
});

final equipmentAcquisitionRepositoryProvider =
    Provider<EquipmentAcquisitionRepository>(
  (ref) => EquipmentAcquisitionLocalDataSource(),
);

final equipmentAcquisitionGatewayProvider =
    Provider<EquipmentAcquisitionGateway>(
  (ref) => EquipmentAcquisitionHttpGateway(
    ref.watch(sessionApiClientProvider),
  ),
);

final equipmentAcquisitionCommandIntentRepositoryProvider =
    Provider<CommandIntentRepository>(
  (ref) => CommandIntentLocalDataSource(),
);

final equipmentAcquisitionOperationIdFactoryProvider =
    Provider<String Function()>(
  (ref) => const Uuid().v4,
);

final equipmentAcquisitionDatabaseManagerProvider =
    Provider<AuthScopedDatabaseManager>(
  (ref) => AuthScopedDatabaseManager.instance,
);

final equipmentAcquisitionServiceOrderRepositoryProvider =
    Provider<ServiceOrderRepository>(
  (ref) => ServiceOrderLocalDataSource(),
);

class EquipmentAcquisitionsNotifier
    extends AutoDisposeAsyncNotifier<List<EquipmentAcquisitionEntity>> {
  bool _isInFlight = false;

  @override
  Future<List<EquipmentAcquisitionEntity>> build() async {
    final binding = _captureBinding(
      ref.watch(authenticatedSessionKeyProvider),
    );
    ref.watch(isOnlineSessionProvider);
    _ensureBindingCurrent(binding);
    await ref
        .read(equipmentAcquisitionCommandIntentRepositoryProvider)
        .recoverInterruptedSending(
          ownedCommandTypes: equipmentAcquisitionOwnedCommandTypes,
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
    return _load(binding);
  }

  Future<EquipmentAcquisitionEntity> createFromPreAcquisition({
    required String preAcquisitionId,
  }) async {
    final binding = _captureProfessionalBinding();
    return _runCommand(binding, () async {
      final database = binding.databaseHandle.database;
      final preAcquisition = await ref
          .read(preAcquisitionRepositoryProvider)
          .findById(preAcquisitionId, executor: database);
      _ensureBindingCurrent(binding);
      if (preAcquisition == null ||
          preAcquisition.organizationId !=
              (binding.scope as ProfessionalAuthScope).organizationId) {
        throw StateError(
          'PreAcquisition is not available in the authenticated scope.',
        );
      }
      if (preAcquisition.status != PreAcquisitionStatus.approved) {
        throw StateError('PreAcquisition must be approved before CREATE.');
      }
      if (preAcquisition.offeredAmountMinor != null &&
          (preAcquisition.offeredAmountMinor! < 1 ||
              preAcquisition.offeredAmountMinor! > 9999999999)) {
        throw ArgumentError.value(
          preAcquisition.offeredAmountMinor,
          'offeredAmountMinor',
          'An acquisition offer must be between 1 and 9999999999.',
        );
      }
      normalizeEquipmentAcquisitionNotes(preAcquisition.notes);

      final equipment = await ref
          .read(equipmentRepositoryProvider)
          .findById(preAcquisition.equipmentId, executor: database);
      _ensureBindingCurrent(binding);
      _assertEligibleEquipment(equipment);
      if (equipment!.customerId != preAcquisition.customerId) {
        throw StateError(
          'PreAcquisition Customer no longer matches the Equipment.',
        );
      }

      final serviceOrderId = preAcquisition.serviceOrderId;
      if (serviceOrderId != null) {
        final order = await ref
            .read(equipmentAcquisitionServiceOrderRepositoryProvider)
            .findById(serviceOrderId, executor: database);
        _ensureBindingCurrent(binding);
        if (order == null ||
            order.equipmentId != preAcquisition.equipmentId ||
            order.customerId != preAcquisition.customerId) {
          throw StateError(
            'PreAcquisition SERVICE_ORDER correlation is not available.',
          );
        }
      }

      final authoritative = await _executor(binding).createFromPreAcquisition(
        preAcquisition: preAcquisition,
      );
      _ensureBindingCurrent(binding);
      ref.invalidate(preAcquisitionsProvider);
      return authoritative;
    });
  }

  Future<EquipmentAcquisitionEntity> authorize({
    required String acquisitionId,
    required EquipmentConsentMethod consentMethod,
  }) async {
    final binding = _captureCustomerBinding();
    return _runCommand(binding, () async {
      await _requireScopedAcquisition(binding, acquisitionId);
      return _executor(binding).authorize(
        acquisitionId: acquisitionId,
        consentMethod: consentMethod,
      );
    });
  }

  Future<EquipmentAcquisitionEntity> reject({
    required String acquisitionId,
  }) async {
    final binding = _captureCustomerBinding();
    return _runCommand(binding, () async {
      await _requireScopedAcquisition(binding, acquisitionId);
      return _executor(binding).reject(acquisitionId: acquisitionId);
    });
  }

  Future<EquipmentAcquisitionEntity> authorizeInPerson({
    required String acquisitionId,
  }) async {
    final binding = _captureProfessionalBinding();
    return _runCommand(binding, () async {
      final acquisition =
          await _requireScopedAcquisition(binding, acquisitionId);
      if (acquisition.source != EquipmentAcquisitionSource.directOffer) {
        throw StateError(
          'In-person authorization requires a DIRECT_OFFER acquisition.',
        );
      }
      return _executor(binding).authorizeInPerson(acquisitionId: acquisitionId);
    });
  }

  Future<EquipmentAcquisitionEntity> complete({
    required String acquisitionId,
  }) async {
    final binding = _captureProfessionalBinding();
    return _runCommand(binding, () async {
      await _requireScopedAcquisition(binding, acquisitionId);
      final authoritative =
          await _executor(binding).complete(acquisitionId: acquisitionId);
      _ensureBindingCurrent(binding);
      return authoritative;
    });
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    try {
      final records = await _load(binding);
      _ensureBindingCurrent(binding);
      state = AsyncData(records);
    } catch (error, stackTrace) {
      if (_isBindingCurrent(binding)) {
        state = AsyncError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<EquipmentAcquisitionEntity> _runCommand(
    _EquipmentAcquisitionBinding binding,
    Future<EquipmentAcquisitionEntity> Function() command,
  ) async {
    if (_isInFlight) {
      throw StateError('An EquipmentAcquisition command is already in flight.');
    }
    if (!ref.read(isOnlineSessionProvider)) {
      throw const EquipmentAcquisitionCommandException(
        503,
        'EQUIPMENT_ACQUISITION_REQUIRES_ONLINE_SESSION',
        safeMessage: 'Conecte-se à internet para executar esta operação.',
      );
    }
    _ensureBindingCurrent(binding);
    _isInFlight = true;
    try {
      final authoritative = await command();
      _ensureBindingCurrent(binding);
      final local = await _loadLocal(binding);
      _ensureBindingCurrent(binding);
      state = AsyncData(local);
      return authoritative;
    } catch (error, stackTrace) {
      if (_isBindingCurrent(binding)) {
        state = AsyncError(error, stackTrace);
      }
      rethrow;
    } finally {
      _isInFlight = false;
    }
  }

  Future<List<EquipmentAcquisitionEntity>> _load(
    _EquipmentAcquisitionBinding binding,
  ) async {
    if (!ref.read(isOnlineSessionProvider)) return _loadLocal(binding);
    final authoritative =
        await ref.read(equipmentAcquisitionGatewayProvider).listAll();
    _ensureBindingCurrent(binding);
    _validateScope(binding, authoritative);
    final repository = ref.read(equipmentAcquisitionRepositoryProvider);
    final database = binding.databaseHandle.database;
    await database.transaction((txn) async {
      _ensureBindingCurrent(binding);
      for (final acquisition in authoritative) {
        await repository.upsert(acquisition, executor: txn);
        _ensureBindingCurrent(binding);
      }
      await repository.deleteAbsentFrom(
        authoritative.map((value) => value.id).toSet(),
        executor: txn,
      );
    });
    _ensureBindingCurrent(binding);
    return authoritative;
  }

  Future<List<EquipmentAcquisitionEntity>> _loadLocal(
    _EquipmentAcquisitionBinding binding,
  ) async {
    final local =
        await ref.read(equipmentAcquisitionRepositoryProvider).listAll(
              executor: binding.databaseHandle.database,
            );
    _ensureBindingCurrent(binding);
    _validateScope(binding, local);
    return local;
  }

  Future<EquipmentAcquisitionEntity> _requireScopedAcquisition(
    _EquipmentAcquisitionBinding binding,
    String acquisitionId,
  ) async {
    final acquisition =
        await ref.read(equipmentAcquisitionRepositoryProvider).findById(
              acquisitionId,
              executor: binding.databaseHandle.database,
            );
    _ensureBindingCurrent(binding);
    if (acquisition == null) {
      throw StateError(
        'EquipmentAcquisition is not available in the authenticated scope.',
      );
    }
    _validateScope(binding, [acquisition]);
    return acquisition;
  }

  EquipmentAcquisitionCommandExecutor _executor(
    _EquipmentAcquisitionBinding binding,
  ) =>
      EquipmentAcquisitionCommandExecutor(
        gateway: ref.read(equipmentAcquisitionGatewayProvider),
        acquisitionRepository: ref.read(equipmentAcquisitionRepositoryProvider),
        intentRepository:
            ref.read(equipmentAcquisitionCommandIntentRepositoryProvider),
        database: binding.databaseHandle.database,
        isBindingCurrent: () => _isBindingCurrent(binding),
        operationIdFactory:
            ref.read(equipmentAcquisitionOperationIdFactoryProvider),
      );

  _EquipmentAcquisitionBinding _captureProfessionalBinding() {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    if (binding.scope is! ProfessionalAuthScope) {
      throw const EquipmentAcquisitionCommandException(
        403,
        'EQUIPMENT_ACQUISITION_STAFF_CONTEXT_REQUIRED',
      );
    }
    final user = ref.read(currentUserProvider);
    if (user == null || (user.role != 'ADMIN' && user.role != 'TECHNICIAN')) {
      throw const EquipmentAcquisitionCommandException(
        403,
        'EQUIPMENT_ACQUISITION_STAFF_ROLE_REQUIRED',
      );
    }
    return binding;
  }

  _EquipmentAcquisitionBinding _captureCustomerBinding() {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    if (binding.scope is! CustomerAuthScope) {
      throw const EquipmentAcquisitionCommandException(
        403,
        'EQUIPMENT_ACQUISITION_CUSTOMER_CONTEXT_REQUIRED',
      );
    }
    return binding;
  }

  _EquipmentAcquisitionBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw const EquipmentAcquisitionCommandException(
        401,
        'EQUIPMENT_ACQUISITION_UNAUTHENTICATED',
      );
    }
    final scope = sessionKey.scope;
    if (scope is! ProfessionalAuthScope && scope is! CustomerAuthScope) {
      throw const EquipmentAcquisitionCommandException(
        403,
        'EQUIPMENT_ACQUISITION_CONTEXT_REQUIRED',
      );
    }
    final manager = ref.read(equipmentAcquisitionDatabaseManagerProvider);
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the EquipmentAcquisition session.',
      );
    }
    return (
      sessionKey: sessionKey,
      databaseHandle: handle,
      scope: scope,
    );
  }

  void _validateScope(
    _EquipmentAcquisitionBinding binding,
    Iterable<EquipmentAcquisitionEntity> acquisitions,
  ) {
    final crossedScope = switch (binding.scope) {
      ProfessionalAuthScope(:final organizationId) => acquisitions.any(
          (value) => value.organizationId != organizationId,
        ),
      CustomerAuthScope(:final customerId) => acquisitions.any(
          (value) => value.customerId != customerId,
        ),
      _ => true,
    };
    if (crossedScope) {
      throw StateError(
        'EquipmentAcquisition data crossed the authenticated scope.',
      );
    }
  }

  bool _isBindingCurrent(_EquipmentAcquisitionBinding binding) {
    final manager = ref.read(equipmentAcquisitionDatabaseManagerProvider);
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        manager.isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_EquipmentAcquisitionBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError(
        'The EquipmentAcquisition operation belongs to a stale session.',
      );
    }
  }
}

final equipmentAcquisitionsProvider = AutoDisposeAsyncNotifierProvider<
    EquipmentAcquisitionsNotifier, List<EquipmentAcquisitionEntity>>(
  EquipmentAcquisitionsNotifier.new,
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
