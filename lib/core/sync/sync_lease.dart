import 'dart:async';
import 'package:sqflite/sqflite.dart';
import '../database/outbox_dao.dart';

/// Exceptions thrown when a lease is cancelled or invalidated.
final class SyncLeaseInvalidatedException implements Exception {
  final String stage;
  const SyncLeaseInvalidatedException([this.stage = 'unspecified']);

  @override
  String toString() => 'SyncLeaseInvalidatedException(stage: $stage)';
}

/// Thrown by the terminal dispatch gate immediately prior to HTTP transport execution.
/// Contains snapshots of claimed entries to perform Unclaim CAS compensation.
final class SyncDispatchBlockedException implements Exception {
  final List<OutboxItem> claimSnapshots;
  final Map<String, String> claimIds;
  const SyncDispatchBlockedException({
    required this.claimSnapshots,
    required this.claimIds,
  });

  @override
  String toString() =>
      'SyncDispatchBlockedException(blocked ${claimSnapshots.length} operations)';
}

/// Identidade não reutilizável e imutável do lease.
final class LeaseIdentity {
  final String leaseId;
  final int sequence;
  final String? authScope;

  const LeaseIdentity({
    required this.leaseId,
    required this.sequence,
    this.authScope,
  });

  @override
  String toString() =>
      'LeaseIdentity($leaseId, seq: $sequence, scope: $authScope)';
}

enum BarrierState {
  active,
  draining,
  cancelled,
}

/// Represents an active, session-bound credential override for a sync lease.
sealed class BoundCredential {
  const BoundCredential._();

  static const BoundCredential absent = _AbsentCredential();

  static BoundCredential explicit(String? token) => _ExplicitCredential(token);

  String? get pinnedToken => switch (this) {
        _AbsentCredential() => null,
        _ExplicitCredential(token: final t) => t,
      };

  bool get isExplicit => this is _ExplicitCredential;

  bool get hasValidToken => switch (this) {
        _AbsentCredential() => false,
        _ExplicitCredential(token: final t) => t != null && t.trim().isNotEmpty,
      };
}

final class _AbsentCredential extends BoundCredential {
  const _AbsentCredential() : super._();
}

final class _ExplicitCredential extends BoundCredential {
  final String? token;
  const _ExplicitCredential(this.token) : super._();
}

/// Barreira de coordenação transacional e cancelamento para o lease SQLite.
class LeaseCommitBarrier {
  BarrierState _state = BarrierState.active;
  int _activeWorkTransactions = 0;
  int _activeCompensationTransactions = 0;
  int _pendingCompensationReservations = 0;
  final Completer<void> _effectiveCompleter = Completer<void>();

  BarrierState get state => _state;
  bool get isDraining => _state == BarrierState.draining;
  bool get isCancelled => _state == BarrierState.cancelled;
  bool get hasPendingUnsentClaim => _pendingCompensationReservations > 0;
  Future<void> get whenEffective => _effectiveCompleter.future;

  /// Admissão síncrona atômica de uma transação de trabalho normal.
  /// Lança [SyncLeaseInvalidatedException] se o lease não estiver estritamente ativo.
  Future<T> runWorkTransaction<T>({
    required Database db,
    required String stage,
    Future<void> Function(String stage)? onBeforeCommit,
    bool Function()? isCancelled,
    required Future<T> Function(Transaction txn) action,
  }) async {
    final cancelled = isCancelled?.call() ?? false;
    if (_state != BarrierState.active || cancelled) {
      throw SyncLeaseInvalidatedException(stage);
    }
    _activeWorkTransactions++;
    try {
      return await db.transaction<T>((txn) async {
        final duringActionCancelled = isCancelled?.call() ?? false;
        if (_state != BarrierState.active || duringActionCancelled) {
          throw SyncLeaseInvalidatedException(stage);
        }
        final result = await action(txn);
        if (onBeforeCommit != null) {
          await onBeforeCommit(stage);
        }
        final postCallbackCancelled = isCancelled?.call() ?? false;
        if (_state != BarrierState.active || postCallbackCancelled) {
          throw SyncLeaseInvalidatedException(stage);
        }
        return result;
      });
    } finally {
      _activeWorkTransactions--;
      _checkDrainComplete();
    }
  }

  /// Reserva prévia de compensação de Unclaim.
  /// Deve ser chamada ANTES de iniciar a transação de claim no SQLite.
  /// Impede que o barrier mude para `cancelled` antes do término de um claim e
  /// eventual Unclaim CAS.
  void reserveUnclaimCompensation() {
    _pendingCompensationReservations++;
  }

  /// Releases a reservation for claims that did not commit or are no longer
  /// eligible for compensation. Must be called exactly once per reservation.
  void releaseUnclaimReservation() {
    if (_pendingCompensationReservations == 0) {
      throw StateError('No Unclaim compensation reservation is available.');
    }
    _pendingCompensationReservations--;
    _checkDrainComplete();
  }

  /// Marca que a requisição HTTP foi despachada para o transporte (`client.send`).
  /// A partir deste instante, o transporte está em voo; Unclaim não é mais permitido.
  void markDispatchedToTransport() {
    releaseUnclaimReservation();
  }

  /// Executa transação compensatória de Unclaim CAS durante drenagem ou cancelamento.
  /// É admitida mesmo em estado draining.
  Future<T> runUnclaimTransaction<T>({
    required Database db,
    required Future<T> Function(Transaction txn) action,
  }) async {
    _activeCompensationTransactions++;
    try {
      final result = await db.transaction<T>((txn) async => await action(txn));
      releaseUnclaimReservation();
      return result;
    } finally {
      _activeCompensationTransactions--;
      _checkDrainComplete();
    }
  }

  /// Solicita cancelamento do lease.
  void requestCancellation() {
    if (_state == BarrierState.cancelled) return;
    _state = BarrierState.draining;
    _checkDrainComplete();
  }

  void _checkDrainComplete() {
    if (_state == BarrierState.draining &&
        _activeWorkTransactions == 0 &&
        _activeCompensationTransactions == 0 &&
        _pendingCompensationReservations == 0) {
      _state = BarrierState.cancelled;
      if (!_effectiveCompleter.isCompleted) {
        _effectiveCompleter.complete();
      }
    }
  }
}

/// A session-bound sync lease that binds a single logical sync cycle to:
/// 1. The database instance captured for the initiating scope;
/// 2. An explicit authentication credential captured for the initiating session;
/// 3. A lifecycle validity / cancellation guard;
/// 4. A [LeaseCommitBarrier] coordinating SQLite writes and atomic cancellation.
class SyncLease {
  final Database? db;
  final BoundCredential credential;
  final bool Function() isCancelled;
  final LeaseIdentity? identity;
  final LeaseCommitBarrier barrier;

  SyncLease({
    this.db,
    required this.credential,
    required this.isCancelled,
    this.identity,
    LeaseCommitBarrier? barrier,
  }) : barrier = barrier ?? LeaseCommitBarrier();

  /// Positive validity check: caller predicate must be false AND barrier must be active.
  bool get isStillValid =>
      !isCancelled() && barrier.state == BarrierState.active;

  String? get authToken => credential.pinnedToken;
}
