import 'dart:convert';
import 'dart:math';
import '../database/outbox_dao.dart';
import '../network/api_client.dart';

class OutboxProcessor {
  final OutboxDao outboxDao;
  final ApiClient apiClient;
  bool _isProcessing = false;

  OutboxProcessor({required this.outboxDao, required this.apiClient});

  Future<void> processOutbox() async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      final pendingEntries = await outboxDao.getPendingEntries(limit: 10);
      if (pendingEntries.isEmpty) {
        _isProcessing = false;
        return;
      }

      final payload = {
        'entries': pendingEntries.map((e) => e.toMap()).toList(),
      };

      final response = await apiClient.post(
        '/sync/push',
        body: payload,
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>? ?? [];

        for (final res in results) {
          final opId = res['operationId'] as String;
          final status = res['status'] as String;

          if (status == 'SYNCED') {
            await outboxDao.updateStatus(opId, 'SYNCED');
          } else {
            final entry = pendingEntries.firstWhere((e) => e.operationId == opId);
            final nextAttempts = entry.attemptCount + 1;
            await outboxDao.updateStatus(opId, 'FAILED', attemptCount: nextAttempts);
          }
        }
      }
    } catch (e) {
      // Backoff + Jitter on failure
    } finally {
      _isProcessing = false;
    }
  }

  int calculateBackoffDelay(int attemptCount) {
    const baseDelaySeconds = 2;
    const maxDelaySeconds = 300;
    final exponential = pow(2, min(attemptCount, 8)).toInt() * baseDelaySeconds;
    final jitter = Random().nextInt(3);
    return min(exponential + jitter, maxDelaySeconds);
  }
}
