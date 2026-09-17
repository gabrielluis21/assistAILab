import 'dart:convert';
import '../../core/database/assert_web_no_sqlite.dart';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import '../network/api_client.dart';
import '../database/sqlite_database.dart';
import '../database/outbox_dao.dart';
import 'sync_lease.dart';
import 'sync_projection_applier.dart';

/// HTTP response failure returned by a Sync endpoint.
final class SyncHttpException implements Exception {
  final int statusCode;
  final String operation;
  final String responseBody;

  const SyncHttpException({
    required this.statusCode,
    required this.operation,
    required this.responseBody,
  });

  @override
  String toString() =>
      'SyncHttpException($operation, HTTP $statusCode): $responseBody';
}

class SyncPushSummary {
  final int totalProcessed;
  final int syncedCount;
  final int failedCount;
  final int conflictCount;

  const SyncPushSummary({
    this.totalProcessed = 0,
    this.syncedCount = 0,
    this.failedCount = 0,
    this.conflictCount = 0,
  });

  bool get hasFailures => failedCount > 0 || conflictCount > 0;
}

class SyncPullSummary {
  final int totalChanges;
  final String? nextCursor;

  const SyncPullSummary({
    this.totalChanges = 0,
    this.nextCursor,
  });
}

class SyncEngine {
  final ApiClient apiClient;
  final OutboxDao outboxDao;

  SyncEngine({
    required this.apiClient,
    OutboxDao? outboxDao,
  }) : outboxDao = outboxDao ?? OutboxDao();

  Future<String?> getLocalCursor({DatabaseExecutor? executor}) async {
    assertWebNoSqlite();
    final db = executor ?? await SqliteDatabase.instance;
    final res = await db
        .query('sync_metadata', where: 'key = ?', whereArgs: ['last_cursor']);
    if (res.isNotEmpty) {
      return res.first['value'] as String?;
    }
    return null;
  }

  Future<void> saveLocalCursor(
    String cursor, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'sync_metadata',
      {'key': 'last_cursor', 'value': cursor},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> ensureV2Bootstrap({required SyncLease lease}) async {
    if (!lease.isStillValid || lease.db == null) return;
    final db = lease.db!;
    final metadata = await db.query(
      'sync_metadata',
      where: 'key IN (?, ?, ?)',
      whereArgs: [
        'sync_contract_version',
        'sync_bootstrap_proof',
        'last_cursor',
      ],
    );
    final values = {
      for (final row in metadata) row['key'] as String: row['value'] as String,
    };
    if (values['sync_contract_version'] == '2' &&
        (values['sync_bootstrap_proof']?.isNotEmpty ?? false) &&
        (values['last_cursor']?.isNotEmpty ?? false)) {
      return;
    }

    const pageSize = 100;
    String? continuationToken;
    String? bootstrapCursor;
    String? bootstrapProof;
    final records = <Map<String, dynamic>>[];
    do {
      if (!lease.isStillValid) return;
      final response = await apiClient.postBound(
        '/sync/bootstrap',
        lease.credential,
        body: {
          'contractVersion': 2,
          'limit': pageSize,
          if (continuationToken != null) 'continuationToken': continuationToken,
        },
      ).timeout(const Duration(seconds: 15));
      if (!lease.isStillValid) return;
      if (response.statusCode != 200) {
        throw SyncHttpException(
          statusCode: response.statusCode,
          operation: 'bootstrap',
          responseBody: response.body,
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic> ||
          decoded['contractVersion'] != 2 ||
          decoded['complete'] is! bool) {
        throw const FormatException('Invalid sync v2 bootstrap response.');
      }
      final cursor = decoded['bootstrapCursor'];
      if (cursor is! String ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(cursor) ||
          bootstrapCursor != null && bootstrapCursor != cursor) {
        throw const FormatException('Invalid sync v2 bootstrap cursor.');
      }
      bootstrapCursor = cursor;
      final pageRecords = decoded['records'];
      if (pageRecords is! List) {
        throw const FormatException('Invalid sync v2 bootstrap records.');
      }
      for (final record in pageRecords) {
        if (record is! Map<String, dynamic>) {
          throw const FormatException('Invalid sync v2 bootstrap record.');
        }
        records.add(record);
      }
      final complete = decoded['complete'] as bool;
      if (complete) {
        if (decoded['continuationToken'] != null ||
            decoded['bootstrapProof'] is! String ||
            (decoded['bootstrapProof'] as String).isEmpty) {
          throw const FormatException('Incomplete sync v2 bootstrap proof.');
        }
        bootstrapProof = decoded['bootstrapProof'] as String;
        continuationToken = null;
      } else {
        if (decoded['bootstrapProof'] != null ||
            decoded['continuationToken'] is! String ||
            (decoded['continuationToken'] as String).isEmpty) {
          throw const FormatException('Invalid bootstrap continuation.');
        }
        continuationToken = decoded['continuationToken'] as String;
      }
    } while (continuationToken != null);

    if (!lease.isStillValid) return;
    await db.transaction((txn) async {
      await SyncProjectionApplier.replaceBootstrap(txn, records);
      for (final entry in {
        'sync_contract_version': '2',
        'sync_bootstrap_proof': bootstrapProof,
        'last_cursor': bootstrapCursor,
      }.entries) {
        await txn.insert(
          'sync_metadata',
          {'key': entry.key, 'value': entry.value},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
    });
  }

  Future<String> _requiredBootstrapProof(DatabaseExecutor db) async {
    final result = await db.query(
      'sync_metadata',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['sync_bootstrap_proof'],
      limit: 1,
    );
    final proof = result.isEmpty ? null : result.first['value'];
    if (proof is! String || proof.isEmpty) {
      throw StateError('Sync v2 bootstrap proof is unavailable.');
    }
    return proof;
  }

  Future<void> _invalidateV2Bootstrap(Database db) async {
    await db.delete(
      'sync_metadata',
      where: 'key IN (?, ?, ?)',
      whereArgs: [
        'sync_contract_version',
        'sync_bootstrap_proof',
        'last_cursor',
      ],
    );
  }

  /// Calculates next retry timestamp using Exponential Backoff + Jitter
  DateTime calculateNextRetryAt(int attemptCount) {
    const baseDelaySeconds = 2;
    const maxDelaySeconds = 300; // 5 minutes max
    final expDelay = baseDelaySeconds * pow(2, attemptCount).toInt();
    final cappedDelay = min(expDelay, maxDelaySeconds);
    final jitter = Random().nextInt(3); // 0-2 seconds jitter
    return DateTime.now().add(Duration(seconds: cappedDelay + jitter));
  }

  /// Executes push for pending outbox entries in batches.
  Future<SyncPushSummary> pushPendingOutbox({
    int batchSize = 20,
    Database? db,
    SyncLease? lease,
  }) async {
    assertWebNoSqlite();
    if (lease == null) return const SyncPushSummary();
    // 1. Validate lease lifecycle
    if (!lease.isStillValid) {
      return const SyncPushSummary();
    }

    // A leased native cycle must never fall through to the process-global DB.
    if (lease.db == null) {
      return const SyncPushSummary();
    }

    // 2. Validate explicit credential (fail-closed before any DB mutations or HTTP)
    if (!lease.credential.hasValidToken) {
      return const SyncPushSummary();
    }

    await ensureV2Bootstrap(lease: lease);
    if (!lease.isStillValid) return const SyncPushSummary();

    // 3. Resolve/use bound DB
    final targetDb = lease.db!;

    // 4. Read pending entries
    final rawPendingEntries = await outboxDao.getPendingEntries(
      limit: batchSize,
      executor: targetDb,
    );
    final pendingEntries = <OutboxItem>[];
    for (final entry in rawPendingEntries) {
      final type = entry.entityType.toUpperCase();
      if (type == 'PAYMENT' || type == 'PART') {
        await outboxDao.updateStatus(
          entry.operationId,
          'REQUIRES_ATTENTION',
          lastError: type == 'PAYMENT'
              ? 'FINANCE_COMMAND_REQUIRED'
              : 'PART_TENANCY_REQUIRED',
          executor: targetDb,
        );
      } else {
        pendingEntries.add(entry);
      }
    }
    if (pendingEntries.isEmpty) {
      return const SyncPushSummary();
    }

    if (!lease.isStillValid) {
      return const SyncPushSummary();
    }

    final proof = await _requiredBootstrapProof(targetDb);
    final payload = {
      'contractVersion': 2,
      'entries': pendingEntries.map((e) => e.toApiPayload()).toList(),
    };

    // 5. Only then mark entries PROCESSING
    final nowIso = DateTime.now().toIso8601String();
    for (final item in pendingEntries) {
      await outboxDao.updateStatus(
        item.operationId,
        'PROCESSING',
        lastAttemptAt: nowIso,
        executor: targetDb,
      );
    }

    if (!lease.isStillValid) {
      return const SyncPushSummary();
    }

    // 6. Issue HTTP
    int synced = 0;
    int failed = 0;
    int conflict = 0;

    try {
      final response = await apiClient.postBoundWithHeaders(
        '/sync/push',
        lease.credential,
        body: payload,
        headers: {'X-Sync-Bootstrap-Proof': proof},
      ).timeout(const Duration(seconds: 15));

      if (!lease.isStillValid) {
        return SyncPushSummary(
          totalProcessed: pendingEntries.length,
          syncedCount: synced,
          failedCount: failed,
          conflictCount: conflict,
        );
      }

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>? ?? [];

        for (final res in results) {
          final opId = res['operationId'] as String;
          final status = res['status'] as String;
          final error = res['error'] as String?;

          if (status == 'SYNCED') {
            await outboxDao.updateStatus(
              opId,
              'SYNCED',
              executor: targetDb,
            );
            synced++;
          } else {
            final existing =
                pendingEntries.firstWhere((e) => e.operationId == opId);
            final newAttempts = existing.attemptCount + 1;
            final nextRetry =
                calculateNextRetryAt(newAttempts).toIso8601String();
            final finalStatus = status == 'CONFLICT' ? 'CONFLICT' : 'FAILED';

            if (status == 'CONFLICT') {
              conflict++;
            } else {
              failed++;
            }

            await outboxDao.updateStatus(
              opId,
              finalStatus,
              attemptCount: newAttempts,
              lastAttemptAt: DateTime.now().toIso8601String(),
              nextRetryAt: nextRetry,
              lastError: error ?? 'Sync rejected by server',
              executor: targetDb,
            );
          }
        }
      } else {
        // HTTP Server or Auth Error - apply backoff to all batch entries
        failed += pendingEntries.length;
        for (final item in pendingEntries) {
          final newAttempts = item.attemptCount + 1;
          final nextRetry = calculateNextRetryAt(newAttempts).toIso8601String();
          await outboxDao.updateStatus(
            item.operationId,
            'FAILED',
            attemptCount: newAttempts,
            lastAttemptAt: DateTime.now().toIso8601String(),
            nextRetryAt: nextRetry,
            lastError: 'HTTP ${response.statusCode}: ${response.body}',
            executor: targetDb,
          );
        }
        throw SyncHttpException(
          statusCode: response.statusCode,
          operation: 'push',
          responseBody: response.body,
        );
      }
    } catch (e) {
      // Network or timeout exception - schedule retries safely
      if (synced == 0 && failed == 0 && conflict == 0) {
        failed += pendingEntries.length;
        for (final item in pendingEntries) {
          final newAttempts = item.attemptCount + 1;
          final nextRetry = calculateNextRetryAt(newAttempts).toIso8601String();
          await outboxDao.updateStatus(
            item.operationId,
            'FAILED',
            attemptCount: newAttempts,
            lastAttemptAt: DateTime.now().toIso8601String(),
            nextRetryAt: nextRetry,
            lastError: e.toString(),
            executor: targetDb,
          );
        }
      }
      rethrow;
    }

    return SyncPushSummary(
      totalProcessed: pendingEntries.length,
      syncedCount: synced,
      failedCount: failed,
      conflictCount: conflict,
    );
  }

  /// Executes pull to fetch incremental server changes using atomic cursor transactions.
  ///
  /// Termination criteria (cursor-progress based, not changes.length):
  /// - previousCursor == nextCursor → cursor stabilised, stop.
  /// - maxPullPagesPerCycle (10) reached → stop to avoid infinite loops.
  /// - malformed or regressive nextCursor → fail closed without persistence.
  Future<SyncPullSummary> pullIncrementalChanges({
    int pullPageSize = 50,
    int maxPullPagesPerCycle = 10,
    Database? db,
    SyncLease? lease,
  }) async {
    if (lease == null) return const SyncPullSummary();
    if (!lease.isStillValid) {
      return const SyncPullSummary();
    }
    // A leased native cycle must never fall through to the process-global DB.
    if (lease.db == null) {
      return const SyncPullSummary();
    }
    // Fail-closed credential guard for the pull phase.
    if (!lease.credential.hasValidToken) {
      return const SyncPullSummary();
    }

    await ensureV2Bootstrap(lease: lease);
    if (!lease.isStillValid) return const SyncPullSummary();
    final targetDb = lease.db!;
    int totalPulled = 0;
    String? latestCursor = await getLocalCursor(executor: targetDb);
    final proof = await _requiredBootstrapProof(targetDb);
    int pageCount = 0;

    while (pageCount < maxPullPagesPerCycle) {
      if (!lease.isStillValid) {
        break;
      }

      if (latestCursor == null || latestCursor.isEmpty) {
        throw StateError('Sync v2 cursor is unavailable after bootstrap.');
      }
      final currentCursorValue = _parseCanonicalIncrementalCursor(
        latestCursor,
        field: 'currentCursor',
      );
      final cursorParam =
          '?contractVersion=2&cursor=$latestCursor&limit=$pullPageSize';

      final response = await apiClient.getBoundWithHeaders(
        '/sync/changes$cursorParam',
        lease.credential,
        headers: {'X-Sync-Bootstrap-Proof': proof},
      ).timeout(const Duration(seconds: 15));

      if (!lease.isStillValid) {
        break;
      }

      if (response.statusCode != 200) {
        if (response.statusCode == 409 &&
            (response.body.contains('SYNC_V2_REFRESH_REQUIRED') ||
                response.body.contains('SYNC_V2_BOOTSTRAP_REQUIRED'))) {
          await _invalidateV2Bootstrap(targetDb);
        }
        throw SyncHttpException(
          statusCode: response.statusCode,
          operation: 'pull',
          responseBody: response.body,
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid incremental Sync response.');
      }
      final body = decoded;
      final nextCursor = body['nextCursor'];
      final nextCursorValue = nextCursor == null
          ? null
          : _parseCanonicalIncrementalCursor(
              nextCursor,
              field: 'nextCursor',
            );
      final nextCursorText = nextCursor as String?;
      if (nextCursorValue != null && nextCursorValue < currentCursorValue) {
        throw const FormatException(
          'Incremental Sync nextCursor must not regress.',
        );
      }
      final changes = body['changes'] as List<dynamic>? ?? [];

      pageCount++;

      // BEGIN ATOMIC TRANSACTION (Changes + Cursor) bound to targetDb
      await targetDb.transaction((txn) async {
        for (final change in changes) {
          await SyncProjectionApplier.applyChange(
            txn,
            Map<String, dynamic>.from(change as Map),
          );
        }

        // Persist nextCursor atomically inside the transaction
        if (nextCursorText != null) {
          await txn.insert(
            'sync_metadata',
            {'key': 'last_cursor', 'value': nextCursorText},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });

      totalPulled += changes.length;

      // Cursor-progress termination:
      // Stop when cursor did not advance (stabilised) or server sent no cursor.
      final cursorAdvanced =
          nextCursorText != null && nextCursorText != latestCursor;

      if (cursorAdvanced) {
        latestCursor = nextCursorText;
      } else {
        // Cursor stabilised or exhausted — no more pages.
        break;
      }
    }

    return SyncPullSummary(
      totalChanges: totalPulled,
      nextCursor: latestCursor,
    );
  }

  static BigInt _parseCanonicalIncrementalCursor(
    Object? value, {
    required String field,
  }) {
    if (value is! String || !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(value)) {
      throw FormatException(
        'Incremental Sync $field must be a canonical decimal string.',
      );
    }
    return BigInt.parse(value);
  }
}
