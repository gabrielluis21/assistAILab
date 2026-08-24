import '../database/outbox_dao.dart';
import '../network/api_client.dart';
import 'sync_engine.dart';

/// Legacy adapter for OutboxProcessor delegating directly to SyncEngine.
class OutboxProcessor {
  final OutboxDao outboxDao;
  final ApiClient apiClient;
  final SyncEngine _syncEngine;

  OutboxProcessor({
    required this.outboxDao,
    required this.apiClient,
  }) : _syncEngine = SyncEngine(apiClient: apiClient, outboxDao: outboxDao);

  Future<void> processOutbox() async {
    try {
      await _syncEngine.pushPendingOutbox();
    } catch (_) {
      // Ignored for legacy compatibility
    }
  }

  int calculateBackoffDelay(int attemptCount) {
    return _syncEngine
        .calculateNextRetryAt(attemptCount)
        .difference(DateTime.now())
        .inSeconds;
  }
}
