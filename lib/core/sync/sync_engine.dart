import 'dart:convert';
import '../../core/database/assert_web_no_sqlite.dart';
import 'dart:math';
import 'package:sqflite/sqflite.dart';
import '../network/api_client.dart';
import '../database/sqlite_database.dart';
import '../database/outbox_dao.dart';
import 'sync_lease.dart';
import 'sync_projection_applier.dart';

const Set<String> _unresolvedSyncConflictCodes = {
  'IDEMPOTENCY_OPERATION_IN_PROGRESS',
  'IDEMPOTENCY_KEY_REUSE',
  'LEGACY_OPERATION_RECONCILIATION_REQUIRED',
  'IDEMPOTENCY_STATE_CONFLICT',
};

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

final class _SyncLeaseInvalidated implements Exception {
  const _SyncLeaseInvalidated();
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
    final expDelay = attemptCount >= 8
        ? maxDelaySeconds
        : baseDelaySeconds * pow(2, attemptCount).toInt();
    final cappedDelay = min(expDelay, maxDelaySeconds);
    final jitter = Random().nextInt(3); // 0-2 seconds jitter
    return DateTime.now().add(
      Duration(seconds: min(maxDelaySeconds, cappedDelay + jitter)),
    );
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
      if (type == 'PAYMENT' || type == 'PART' || type == 'PRE_ACQUISITION') {
        final canProveUnsent = entry.status == OutboxStatus.pending.value &&
            entry.remoteDisposition == RemoteDisposition.unsent &&
            entry.attemptCount == 0 &&
            entry.lastAttemptAt == null;
        await outboxDao.transition(
          operationId: entry.operationId,
          fromStatus: entry.status,
          fromDisposition: entry.remoteDisposition,
          toStatus: 'REQUIRES_ATTENTION',
          toDisposition: canProveUnsent
              ? RemoteDisposition.unsent
              : RemoteDisposition.ambiguous,
          lastError: switch (type) {
            'PAYMENT' => 'FINANCE_COMMAND_REQUIRED',
            'PART' => 'PART_TENANCY_REQUIRED',
            _ => 'PRE_ACQUISITION_LOCAL_ONLY',
          },
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

    // Persist ambiguity before network I/O: any interruption after this point
    // must not silently replay an operation whose remote result is unknown.
    final nowIso = DateTime.now().toIso8601String();
    final attemptIdentities =
        <String, ({int attemptCount, String lastAttemptAt})>{};
    await targetDb.transaction((txn) async {
      for (final item in pendingEntries) {
        final attemptCount = item.attemptCount + 1;
        await outboxDao.transition(
          operationId: item.operationId,
          fromStatus: item.status,
          fromDisposition: item.remoteDisposition,
          toStatus: 'PROCESSING',
          toDisposition: RemoteDisposition.ambiguous,
          attemptCount: attemptCount,
          lastAttemptAt: nowIso,
          requireUnattempted: true,
          executor: txn,
        );
        attemptIdentities[item.operationId] = (
          attemptCount: attemptCount,
          lastAttemptAt: nowIso,
        );
      }
    });

    if (!lease.isStillValid) {
      return const SyncPushSummary();
    }

    // 6. Issue HTTP
    int synced = 0;
    int failed = 0;
    int conflict = 0;

    SyncPushSummary cancelledSummary() => SyncPushSummary(
          totalProcessed: pendingEntries.length,
          syncedCount: 0,
          failedCount: 0,
          conflictCount: 0,
        );

    Future<bool> transitionClaimed({
      required OutboxItem item,
      required String toStatus,
      required RemoteDisposition toDisposition,
      String? lastError,
      String? nextRetryAt,
      required DatabaseExecutor executor,
    }) {
      final attempt = attemptIdentities[item.operationId]!;
      return outboxDao.transition(
        operationId: item.operationId,
        fromStatus: 'PROCESSING',
        fromDisposition: RemoteDisposition.ambiguous,
        toStatus: toStatus,
        toDisposition: toDisposition,
        nextRetryAt: nextRetryAt,
        lastError: lastError,
        expectedAttemptCount: attempt.attemptCount,
        expectedLastAttemptAt: attempt.lastAttemptAt,
        executor: executor,
      );
    }

    try {
      final response = await apiClient.postBoundWithHeaders(
        '/sync/push',
        lease.credential,
        body: payload,
        headers: {'X-Sync-Bootstrap-Proof': proof},
      ).timeout(const Duration(seconds: 15));

      if (!lease.isStillValid) {
        return cancelledSummary();
      }

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>? ?? [];
        final knownIds =
            pendingEntries.map((entry) => entry.operationId).toSet();
        final completedIds = <String>{};

        await targetDb.transaction((txn) async {
          for (final res in results) {
            if (!lease.isStillValid) {
              throw const _SyncLeaseInvalidated();
            }
            if (res is! Map<String, dynamic>) continue;
            final rawOpId = res['operationId'];
            if (rawOpId is! String ||
                !knownIds.contains(rawOpId) ||
                !completedIds.add(rawOpId)) {
              continue;
            }
            final item = pendingEntries
                .firstWhere((entry) => entry.operationId == rawOpId);
            final status = res['status'];
            final error = res['error'];

            if (status == 'SYNCED' && error == null) {
              if (await transitionClaimed(
                item: item,
                toStatus: 'SYNCED',
                toDisposition: RemoteDisposition.confirmed,
                executor: txn,
              )) {
                synced++;
              }
            } else if (status == 'FAILED' &&
                (error is String && error.isNotEmpty)) {
              // The v2 backend emits per-entry FAILED only for checks performed
              // before mutation or for domain failures caught after the
              // transaction rollback. Infrastructure failures escape the
              // handler as batch HTTP errors and remain AMBIGUOUS below.
              if (await transitionClaimed(
                item: item,
                toStatus: 'FAILED_FATAL',
                toDisposition: RemoteDisposition.confirmed,
                lastError: error,
                executor: txn,
              )) {
                failed++;
              }
            } else if (status == 'CONFLICT' &&
                (error is String && error.isNotEmpty)) {
              // These explicit codes cover every unresolved idempotency result
              // in the current backend contract. Unknown conflict codes remain
              // quarantined below; none is promoted to CONFIRMED by status alone.
              final unresolved = _unresolvedSyncConflictCodes.contains(error);
              if (await transitionClaimed(
                item: item,
                toStatus: unresolved ? 'CONFLICT' : 'REQUIRES_ATTENTION',
                toDisposition: RemoteDisposition.ambiguous,
                lastError: unresolved ? error : 'SYNC_CONFLICT_UNKNOWN:$error',
                executor: txn,
              )) {
                if (unresolved) {
                  conflict++;
                } else {
                  failed++;
                }
              }
            } else {
              await transitionClaimed(
                item: item,
                toStatus: 'REQUIRES_ATTENTION',
                toDisposition: RemoteDisposition.ambiguous,
                lastError: 'SYNC_RESULT_UNKNOWN',
                executor: txn,
              );
            }
          }
          // Missing or malformed result entries remain ambiguous and are
          // quarantined for reconciliation; they are never implicitly retried.
          for (final item in pendingEntries.where(
            (entry) => !completedIds.contains(entry.operationId),
          )) {
            if (!lease.isStillValid) {
              throw const _SyncLeaseInvalidated();
            }
            await transitionClaimed(
              item: item,
              toStatus: 'REQUIRES_ATTENTION',
              toDisposition: RemoteDisposition.ambiguous,
              lastError: 'SYNC_RESULT_MISSING',
              executor: txn,
            );
          }
          if (!lease.isStillValid) {
            throw const _SyncLeaseInvalidated();
          }
        });
      } else {
        // Batch HTTP classification rationale: backend 400 body validation,
        // 401 authentication, and 403/409 bootstrap-proof failures are request
        // level; the handler reports entry outcomes inside HTTP 200 `results`.
        // The Sync route has no 429 handler, while 408/5xx may follow applied
        // work. Since a client cannot prove the response source or bind a
        // batch status to every operation, every non-200 remains ambiguous.
        await targetDb.transaction((txn) async {
          for (final item in pendingEntries) {
            if (!lease.isStillValid) {
              throw const _SyncLeaseInvalidated();
            }
            await transitionClaimed(
              item: item,
              toStatus: 'REQUIRES_ATTENTION',
              toDisposition: RemoteDisposition.ambiguous,
              lastError: 'HTTP ${response.statusCode}: ${response.body}',
              executor: txn,
            );
          }
          if (!lease.isStillValid) {
            throw const _SyncLeaseInvalidated();
          }
        });
        if (!lease.isStillValid) return cancelledSummary();
        throw SyncHttpException(
          statusCode: response.statusCode,
          operation: 'push',
          responseBody: response.body,
        );
      }
    } catch (e) {
      // A stale cycle must stop before touching its database or publishing an
      // error. The coordinator will discard this neutral summary on cancel.
      if (!lease.isStillValid || e is _SyncLeaseInvalidated) {
        return cancelledSummary();
      }
      try {
        await targetDb.transaction((txn) async {
          for (final item in pendingEntries) {
            if (!lease.isStillValid) {
              throw const _SyncLeaseInvalidated();
            }
            await transitionClaimed(
              item: item,
              toStatus: 'REQUIRES_ATTENTION',
              toDisposition: RemoteDisposition.ambiguous,
              lastError: e.toString(),
              executor: txn,
            );
          }
          if (!lease.isStillValid) {
            throw const _SyncLeaseInvalidated();
          }
        });
      } on _SyncLeaseInvalidated {
        return cancelledSummary();
      }
      if (!lease.isStillValid) {
        return cancelledSummary();
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
