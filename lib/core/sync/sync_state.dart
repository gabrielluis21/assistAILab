import 'sync_trigger.dart';

/// Status of the background synchronization system.
enum SyncStatus {
  idle,
  syncing,
  error,
  offline,
  paused,
}

/// Immutable state model representing the synchronization state.
class SyncState {
  final SyncStatus status;
  final DateTime? lastSyncAt;
  final String? lastError;
  final int pendingOutboxCount;
  final SyncTrigger? lastTrigger;
  final bool isSyncing;

  const SyncState({
    this.status = SyncStatus.idle,
    this.lastSyncAt,
    this.lastError,
    this.pendingOutboxCount = 0,
    this.lastTrigger,
    this.isSyncing = false,
  });

  factory SyncState.initial() => const SyncState();

  SyncState copyWith({
    SyncStatus? status,
    DateTime? lastSyncAt,
    String? lastError,
    int? pendingOutboxCount,
    SyncTrigger? lastTrigger,
    bool? isSyncing,
    bool clearLastError = false,
  }) {
    return SyncState(
      status: status ?? this.status,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastError: clearLastError ? null : (lastError ?? this.lastError),
      pendingOutboxCount: pendingOutboxCount ?? this.pendingOutboxCount,
      lastTrigger: lastTrigger ?? this.lastTrigger,
      isSyncing: isSyncing ?? this.isSyncing,
    );
  }

  bool get isHealthy => lastError == null;
  bool get hasPendingMutations => pendingOutboxCount > 0;

  @override
  String toString() {
    return 'SyncState(status: $status, isSyncing: $isSyncing, pending: $pendingOutboxCount, lastSyncAt: $lastSyncAt, lastError: $lastError)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is SyncState &&
        other.status == status &&
        other.lastSyncAt == lastSyncAt &&
        other.lastError == lastError &&
        other.pendingOutboxCount == pendingOutboxCount &&
        other.lastTrigger == lastTrigger &&
        other.isSyncing == isSyncing;
  }

  @override
  int get hashCode => Object.hash(
        status,
        lastSyncAt,
        lastError,
        pendingOutboxCount,
        lastTrigger,
        isSyncing,
      );
}
