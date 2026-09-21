import 'package:sqflite/sqflite.dart';

import '../../core/commands/command_executor.dart';
import '../../core/commands/command_intent.dart';
import '../../core/database/service_order_repository.dart';
import 'service_order_entity.dart';
import 'staff_so_command_gateway.dart';

// ---------------------------------------------------------------------------
// Command type registry
// ---------------------------------------------------------------------------

enum StaffSoCommandType {
  updateStatus('SO_STATUS_UPDATE'),
  publishInitialQuote('SO_QUOTE_PUBLISH'),
  publishCommercialRevision('SO_QUOTE_REVISE'),
  resumeApprovedScope('SO_QUOTE_RESUME_APPROVED'),
  markReady('SO_MARK_READY'),
  markDelivered('SO_MARK_DELIVERED'),
  recordNotApproved('SO_NOT_APPROVED');

  const StaffSoCommandType(this.wireValue);

  final String wireValue;
}

/// The set of command types owned by the staff SO executor.
///
/// Used by [recoverInterruptedSending] on notifier boot so that any
/// interrupted SENDING intents belonging to these commands are immediately
/// promoted to UNKNOWN — preserving the durable uncertainty guarantee.
const staffSoOwnedCommandTypes = <String>{
  'SO_STATUS_UPDATE',
  'SO_QUOTE_PUBLISH',
  'SO_QUOTE_REVISE',
  'SO_QUOTE_RESUME_APPROVED',
  'SO_MARK_READY',
  'SO_MARK_DELIVERED',
  'SO_NOT_APPROVED',
};

// ---------------------------------------------------------------------------
// Executor
// ---------------------------------------------------------------------------

/// Wraps [CommandExecutor] for each staff-only SO command.
///
/// Design principles (mirrors [PaymentCommandIntentExecutor]):
/// - Each public method constructs a canonical payload and delegates to
///   [_execute], which drives the full intent lifecycle via [CommandExecutor].
/// - The gateway response (authoritative server projection) is committed
///   atomically with the intent closure inside a single database transaction.
/// - Stale-session propagation is left entirely to [CommandExecutor] and
///   [isBindingCurrent]; this class never swallows [StateError].
final class StaffSoCommandIntentExecutor {
  const StaffSoCommandIntentExecutor({
    required this.gateway,
    required this.serviceOrderRepository,
    required this.intentRepository,
    required this.database,
    required this.isBindingCurrent,
    required this.operationIdFactory,
  });

  final StaffSoCommandGateway gateway;
  final ServiceOrderRepository serviceOrderRepository;
  final CommandIntentRepository intentRepository;
  final Database database;
  final bool Function() isBindingCurrent;
  final String Function() operationIdFactory;

  // ── status transition ───────────────────────────────────────────────────

  Future<ServiceOrderEntity> updateStatus({
    required String serviceOrderId,
    required ServiceOrderStatusEnum status,
  }) {
    return _execute(
      commandType: StaffSoCommandType.updateStatus,
      targetId: serviceOrderId,
      payload: {
        'serviceOrderId': serviceOrderId,
        'status': status.toDbString(),
      },
      dispatch: (operationId) => gateway.updateStatus(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
        status: status,
      ),
    );
  }

  // ── quote commands ──────────────────────────────────────────────────────

  Future<ServiceOrderEntity> publishInitialQuote({
    required String serviceOrderId,
    String? changeReason,
  }) {
    final normalizedReason = changeReason?.trim();
    return _execute(
      commandType: StaffSoCommandType.publishInitialQuote,
      targetId: serviceOrderId,
      payload: {
        'serviceOrderId': serviceOrderId,
        if (normalizedReason != null && normalizedReason.isNotEmpty)
          'changeReason': normalizedReason,
      },
      dispatch: (operationId) => gateway.publishInitialQuote(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
        changeReason: normalizedReason,
      ),
    );
  }

  Future<ServiceOrderEntity> publishCommercialRevision({
    required String serviceOrderId,
    String? changeReason,
  }) {
    final normalizedReason = changeReason?.trim();
    return _execute(
      commandType: StaffSoCommandType.publishCommercialRevision,
      targetId: serviceOrderId,
      payload: {
        'serviceOrderId': serviceOrderId,
        if (normalizedReason != null && normalizedReason.isNotEmpty)
          'changeReason': normalizedReason,
      },
      dispatch: (operationId) => gateway.publishCommercialRevision(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
        changeReason: normalizedReason,
      ),
    );
  }

  Future<ServiceOrderEntity> resumeApprovedScope({
    required String serviceOrderId,
  }) {
    return _execute(
      commandType: StaffSoCommandType.resumeApprovedScope,
      targetId: serviceOrderId,
      payload: {'serviceOrderId': serviceOrderId},
      dispatch: (operationId) => gateway.resumeApprovedScope(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
      ),
    );
  }

  // ── execution / delivery commands ───────────────────────────────────────

  Future<ServiceOrderEntity> markReady({
    required String serviceOrderId,
    String? notes,
  }) {
    final normalizedNotes = notes?.trim();
    return _execute(
      commandType: StaffSoCommandType.markReady,
      targetId: serviceOrderId,
      payload: {
        'serviceOrderId': serviceOrderId,
        if (normalizedNotes != null && normalizedNotes.isNotEmpty)
          'notes': normalizedNotes,
      },
      dispatch: (operationId) => gateway.markReady(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
        notes: normalizedNotes,
      ),
    );
  }

  Future<ServiceOrderEntity> markDelivered({
    required String serviceOrderId,
  }) {
    return _execute(
      commandType: StaffSoCommandType.markDelivered,
      targetId: serviceOrderId,
      payload: {'serviceOrderId': serviceOrderId},
      dispatch: (operationId) => gateway.markDelivered(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
      ),
    );
  }

  Future<ServiceOrderEntity> recordNotApproved({
    required String serviceOrderId,
  }) {
    return _execute(
      commandType: StaffSoCommandType.recordNotApproved,
      targetId: serviceOrderId,
      payload: {'serviceOrderId': serviceOrderId},
      dispatch: (operationId) => gateway.recordNotApproved(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
      ),
    );
  }

  // ── shared dispatch ─────────────────────────────────────────────────────

  Future<ServiceOrderEntity> _execute({
    required StaffSoCommandType commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required Future<ServiceOrderEntity> Function(String operationId) dispatch,
  }) {
    return CommandExecutor(
      intentRepository: intentRepository,
      database: database,
      isBindingCurrent: isBindingCurrent,
      operationIdFactory: operationIdFactory,
    ).execute(
      commandType: commandType.wireValue,
      targetId: targetId,
      payload: payload,
      dispatch: dispatch,
      authoritativeCommit: (executor, authoritative) =>
          serviceOrderRepository.upsert(authoritative, executor: executor),
    );
  }
}
