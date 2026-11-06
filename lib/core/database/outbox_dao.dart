import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'sqlite_database.dart';

const Map<String, String> _outboxEntityTables = {
  'CUSTOMER': 'customers',
  'EQUIPMENT': 'equipments',
  'SERVICE_ORDER': 'service_orders',
  'SERVICE_ORDER_ITEM': 'service_order_items',
  'PRE_ACQUISITION': 'pre_acquisitions',
};

enum OutboxStatus {
  pending('PENDING'),
  processing('PROCESSING'),
  failedTransient('FAILED_TRANSIENT'),
  failedFatal('FAILED_FATAL'),
  requiresAttention('REQUIRES_ATTENTION'),
  conflict('CONFLICT'),
  superseded('SUPERSEDED'),
  discarded('DISCARDED'),
  synced('SYNCED');

  const OutboxStatus(this.value);
  final String value;
}

enum RemoteDisposition {
  unsent('UNSENT'),
  ambiguous('AMBIGUOUS'),
  confirmed('CONFIRMED');

  const RemoteDisposition(this.value);
  final String value;
}

final class OutboxTransitionException implements Exception {
  final String message;
  const OutboxTransitionException(this.message);
  @override
  String toString() => message;
}

class OutboxItem {
  final String operationId;
  final String? deviceId;
  final String? userId;
  final String entityType;
  final String entityId;
  final String operationType; // CREATE, UPDATE, DELETE
  final Map<String, dynamic> payload;
  final String createdAt;
  final int attemptCount;
  final String? lastAttemptAt;
  final String? nextRetryAt;
  final String? lastError;
  final String status;
  final RemoteDisposition remoteDisposition;
  // Process state is deliberately separate from domain/business state.

  OutboxItem({
    required this.operationId,
    this.deviceId,
    this.userId,
    required this.entityType,
    required this.entityId,
    required this.operationType,
    required this.payload,
    required this.createdAt,
    this.attemptCount = 0,
    this.lastAttemptAt,
    this.nextRetryAt,
    this.lastError,
    this.status = 'PENDING',
    this.remoteDisposition = RemoteDisposition.unsent,
  });

  /// Formats outbox item for SQLite table persistence (snake_case + json-encoded payload string)
  Map<String, dynamic> toMap() {
    return {
      'operation_id': operationId,
      'device_id': deviceId,
      'user_id': userId,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation_type': operationType,
      'payload': jsonEncode(payload),
      'created_at': createdAt,
      'attempt_count': attemptCount,
      'last_attempt_at': lastAttemptAt,
      'next_retry_at': nextRetryAt,
      'last_error': lastError,
      'status': status,
      'remote_disposition': remoteDisposition.value,
    };
  }

  /// Formats outbox item for backend HTTP `/sync/push` API (camelCase + payload as Map)
  Map<String, dynamic> toApiPayload() {
    return {
      'operationId': operationId,
      if (deviceId != null) 'deviceId': deviceId,
      if (userId != null) 'userId': userId,
      'entityType': entityType,
      'entityId': entityId,
      'operationType': operationType,
      'payload': payload,
      'createdAt': createdAt,
    };
  }

  factory OutboxItem.fromMap(Map<String, dynamic> map) {
    return OutboxItem(
      operationId: map['operation_id'],
      deviceId: map['device_id'],
      userId: map['user_id'],
      entityType: map['entity_type'],
      entityId: map['entity_id'],
      operationType: map['operation_type'],
      payload: jsonDecode(map['payload'] as String),
      createdAt: map['created_at'],
      attemptCount: map['attempt_count'] ?? 0,
      lastAttemptAt: map['last_attempt_at'],
      nextRetryAt: map['next_retry_at'],
      lastError: map['last_error'],
      status: map['status'],
      remoteDisposition: RemoteDisposition.values.firstWhere(
        (value) => value.value == map['remote_disposition'],
        orElse: () => RemoteDisposition.ambiguous,
      ),
    );
  }
}

class OutboxDao {
  Future<void> insert(OutboxItem item, {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'outbox',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<List<OutboxItem>> getPendingEntries({
    int limit = 20,
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final nowIso = DateTime.now().toIso8601String();
    if (db is Database) {
      return db.transaction(
        (txn) => _getPendingEntries(txn, limit: limit, nowIso: nowIso),
      );
    }
    return _getPendingEntries(db, limit: limit, nowIso: nowIso);
  }

  Future<List<OutboxItem>> _getPendingEntries(
    DatabaseExecutor db, {
    required int limit,
    required String nowIso,
  }) async {
    await _quarantineInconsistentPendingEntries(db);
    final maps = await db.query(
      'outbox',
      where:
          "status IN ('PENDING', 'FAILED_TRANSIENT') AND remote_disposition = 'UNSENT' AND attempt_count = 0 AND last_attempt_at IS NULL AND (next_retry_at IS NULL OR next_retry_at <= ?)",
      whereArgs: [nowIso],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return maps.map((m) => OutboxItem.fromMap(m)).toList();
  }

  /// Moves active rows with inconsistent remote state or prior-attempt
  /// evidence out of automatic selection. The compare-and-set protects a row
  /// that another writer changed after this query.
  Future<void> _quarantineInconsistentPendingEntries(
    DatabaseExecutor db,
  ) async {
    final rows = await db.query(
      'outbox',
      where: """
        status IN ('PENDING', 'FAILED_TRANSIENT') AND (
          remote_disposition IS NULL OR remote_disposition != 'UNSENT' OR
          attempt_count != 0 OR last_attempt_at IS NOT NULL
        )
      """,
    );
    for (final row in rows) {
      final previousError = row['last_error'];
      const marker = 'OUTBOX_UNSAFE_AUTOMATIC_SELECTION';
      final error = previousError is String && previousError.isNotEmpty
          ? '$previousError | $marker'
          : marker;
      final where = StringBuffer(
        'operation_id = ? AND status = ? AND last_error ',
      );
      final whereArgs = <Object?>[row['operation_id'], row['status']];
      if (row['last_error'] == null) {
        where.write('IS NULL');
      } else {
        where.write('= ?');
        whereArgs.add(row['last_error']);
      }
      where.write(' AND remote_disposition ');
      if (row['remote_disposition'] == null) {
        where.write('IS NULL');
      } else {
        where.write('= ?');
        whereArgs.add(row['remote_disposition']);
      }
      where.write(' AND attempt_count ');
      if (row['attempt_count'] == null) {
        where.write('IS NULL');
      } else {
        where.write('= ?');
        whereArgs.add(row['attempt_count']);
      }
      where.write(' AND last_attempt_at ');
      if (row['last_attempt_at'] == null) {
        where.write('IS NULL');
      } else {
        where.write('= ?');
        whereArgs.add(row['last_attempt_at']);
      }
      await db.update(
        'outbox',
        {
          'status': 'REQUIRES_ATTENTION',
          'remote_disposition': 'AMBIGUOUS',
          'last_error': error,
        },
        where: where.toString(),
        whereArgs: whereArgs,
      );
    }
  }

  /// Returns false only when a supplied attempt identity no longer matches.
  /// Other failed compare-and-set transitions remain programming errors.
  Future<bool> transition({
    required String operationId,
    required String fromStatus,
    required RemoteDisposition fromDisposition,
    required String toStatus,
    required RemoteDisposition toDisposition,
    int? attemptCount,
    String? lastAttemptAt,
    String? nextRetryAt,
    String? lastError,
    bool requireUnattempted = false,
    int? expectedAttemptCount,
    String? expectedLastAttemptAt,
    DatabaseExecutor? executor,
  }) async {
    if ((expectedAttemptCount == null) != (expectedLastAttemptAt == null)) {
      throw const OutboxTransitionException(
        'Attempt identity requires both attempt_count and last_attempt_at.',
      );
    }
    if (requireUnattempted &&
        (!{
              OutboxStatus.pending.value,
              OutboxStatus.failedTransient.value,
            }.contains(fromStatus) ||
            fromDisposition != RemoteDisposition.unsent ||
            toStatus != OutboxStatus.processing.value ||
            toDisposition != RemoteDisposition.ambiguous)) {
      throw const OutboxTransitionException(
        'Unattempted compare-and-set is only valid when claiming an UNSENT operation.',
      );
    }
    final allowed =
        switch ((fromStatus, fromDisposition, toStatus, toDisposition)) {
      (
        'PENDING',
        RemoteDisposition.unsent,
        'PROCESSING',
        RemoteDisposition.ambiguous
      ) ||
      (
        'FAILED_TRANSIENT',
        RemoteDisposition.unsent,
        'PROCESSING',
        RemoteDisposition.ambiguous
      ) ||
      (
        'PROCESSING',
        RemoteDisposition.ambiguous,
        'SYNCED',
        RemoteDisposition.confirmed
      ) ||
      (
        'PROCESSING',
        RemoteDisposition.ambiguous,
        'CONFLICT',
        RemoteDisposition.ambiguous
      ) ||
      (
        'PROCESSING',
        RemoteDisposition.ambiguous,
        'FAILED_FATAL',
        RemoteDisposition.confirmed
      ) ||
      (
        'PROCESSING',
        RemoteDisposition.ambiguous,
        'REQUIRES_ATTENTION',
        RemoteDisposition.ambiguous
      ) ||
      (
        'PROCESSING',
        RemoteDisposition.ambiguous,
        'REQUIRES_ATTENTION',
        RemoteDisposition.confirmed
      ) ||
      (
        'PENDING',
        RemoteDisposition.unsent,
        'REQUIRES_ATTENTION',
        RemoteDisposition.unsent
      ) ||
      (
        'PENDING',
        RemoteDisposition.unsent,
        'REQUIRES_ATTENTION',
        RemoteDisposition.ambiguous
      ) ||
      (
        'FAILED_TRANSIENT',
        RemoteDisposition.unsent,
        'REQUIRES_ATTENTION',
        RemoteDisposition.ambiguous
      ) ||
      (
        'FAILED_TRANSIENT',
        RemoteDisposition.confirmed,
        'REQUIRES_ATTENTION',
        RemoteDisposition.ambiguous
      ) =>
        true,
      _ => false,
    };
    if (!allowed) {
      throw OutboxTransitionException(
        'Unauthorized Outbox transition: $fromStatus/${fromDisposition.value} -> $toStatus/${toDisposition.value}.',
      );
    }
    final db = executor ?? await SqliteDatabase.instance;
    final values = <String, Object?>{
      'status': toStatus,
      'remote_disposition': toDisposition.value,
      if (attemptCount != null) 'attempt_count': attemptCount,
      if (lastAttemptAt != null) 'last_attempt_at': lastAttemptAt,
      if (nextRetryAt != null) 'next_retry_at': nextRetryAt,
      if (lastError != null) 'last_error': lastError,
    };
    final where = StringBuffer(
      'operation_id = ? AND status = ? AND remote_disposition = ?',
    );
    final whereArgs = <Object?>[
      operationId,
      fromStatus,
      fromDisposition.value,
    ];
    if (requireUnattempted) {
      where.write(' AND attempt_count = 0 AND last_attempt_at IS NULL');
    }
    if (expectedAttemptCount != null && expectedLastAttemptAt != null) {
      where.write(' AND attempt_count = ? AND last_attempt_at = ?');
      whereArgs
        ..add(expectedAttemptCount)
        ..add(expectedLastAttemptAt);
    }
    final changed = await db.update(
      'outbox',
      values,
      where: where.toString(),
      whereArgs: whereArgs,
    );
    if (changed != 1) {
      if (expectedAttemptCount != null) return false;
      throw OutboxTransitionException(
        'Outbox transition compare-and-set failed for $operationId.',
      );
    }
    return true;
  }

  /// Recovers entries stuck in PROCESSING state for more than [timeout] (default 5 minutes)
  /// by quarantining them because the remote result may be ambiguous.
  Future<int> recoverProcessingEntries({
    Duration timeout = const Duration(minutes: 5),
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final cutoff = DateTime.now().subtract(timeout).toIso8601String();
    return db.update(
      'outbox',
      {
        'status': 'REQUIRES_ATTENTION',
        'remote_disposition': 'AMBIGUOUS',
        'last_error': 'Operation timeout: stuck in PROCESSING for > 5 minutes',
      },
      where:
          "status = ? AND remote_disposition = 'AMBIGUOUS' AND (last_attempt_at IS NULL OR last_attempt_at <= ?)",
      whereArgs: ['PROCESSING', cutoff],
    );
  }

  /// Returns total count of pending and failed entries waiting for synchronization.
  Future<int> getPendingCount({DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final res = await db.rawQuery(
      "SELECT COUNT(*) as count FROM outbox WHERE status IN ('PENDING', 'PROCESSING', 'FAILED_TRANSIENT', 'REQUIRES_ATTENTION')",
    );
    if (res.isNotEmpty) {
      return (res.first['count'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  /// Supersedes one known local operation and writes its replacement atomically.
  Future<String> supersede({
    required String oldOperationId,
    required String entityType,
    required String entityId,
    required String oldStatus,
    required RemoteDisposition oldDisposition,
    required OutboxItem replacement,
    required String entityTable,
    required Map<String, Object?> localUpdate,
    Database? database,
  }) async {
    final db = database ?? await SqliteDatabase.instance;
    if (_outboxEntityTables[entityType] != entityTable) {
      throw ArgumentError('Entity type/table pair is not allowed.');
    }
    if (replacement.entityType != entityType ||
        replacement.entityId != entityId ||
        replacement.remoteDisposition != RemoteDisposition.unsent ||
        replacement.status != OutboxStatus.pending.value) {
      throw const OutboxTransitionException(
          'Replacement identity or state is invalid.');
    }
    if (oldStatus == OutboxStatus.processing.value ||
        oldDisposition == RemoteDisposition.ambiguous) {
      throw const OutboxTransitionException(
          'Processing or ambiguous operation cannot be superseded.');
    }
    if (!{
      OutboxStatus.pending.value,
      OutboxStatus.failedTransient.value,
      OutboxStatus.failedFatal.value,
    }.contains(oldStatus)) {
      throw const OutboxTransitionException(
          'Operation state cannot be superseded.');
    }
    if ((oldStatus == OutboxStatus.pending.value &&
            oldDisposition != RemoteDisposition.unsent) ||
        (oldStatus != OutboxStatus.pending.value &&
            oldDisposition != RemoteDisposition.confirmed)) {
      throw const OutboxTransitionException(
        'Operation state and remote disposition are incompatible for supersede.',
      );
    }

    final newOperationId = const Uuid().v4();
    final newItem = OutboxItem(
      operationId: newOperationId,
      deviceId: replacement.deviceId,
      userId: replacement.userId,
      entityType: replacement.entityType,
      entityId: replacement.entityId,
      operationType: replacement.operationType,
      payload: replacement.payload,
      createdAt: replacement.createdAt,
      attemptCount: 0,
      status: OutboxStatus.pending.value,
      remoteDisposition: RemoteDisposition.unsent,
    );

    await db.transaction((txn) async {
      final existing = await txn.query(
        'outbox',
        where: 'operation_id = ?',
        whereArgs: [oldOperationId],
        limit: 1,
      );
      if (existing.length != 1 ||
          existing.single['entity_type'] != entityType ||
          existing.single['entity_id'] != entityId ||
          existing.single['status'] != oldStatus ||
          existing.single['remote_disposition'] != oldDisposition.value) {
        throw const OutboxTransitionException(
            'Old operation no longer matches the expected identity and state.');
      }
      final changed = await txn.update(
        'outbox',
        {'status': OutboxStatus.superseded.value},
        where:
            'operation_id = ? AND entity_type = ? AND entity_id = ? AND status = ? AND remote_disposition = ?',
        whereArgs: [
          oldOperationId,
          entityType,
          entityId,
          oldStatus,
          oldDisposition.value
        ],
      );
      if (changed != 1) {
        throw const OutboxTransitionException(
            'Supersede compare-and-set failed.');
      }
      await txn.insert('outbox', newItem.toMap());
      final updated = await txn.update(
        entityTable,
        localUpdate,
        where: 'id = ?',
        whereArgs: [entityId],
      );
      if (updated != 1) {
        throw const OutboxTransitionException(
            'Local entity update failed during supersede.');
      }
    });
    return newOperationId;
  }

  /// Discards a local CREATE only after validating every operation and known
  /// dependent row in the same transaction as the physical entity deletion.
  Future<void> discardCreate({
    required String entityType,
    required String entityId,
    required String entityTable,
    Database? database,
  }) async {
    final db = database ?? await SqliteDatabase.instance;
    if (_outboxEntityTables[entityType] != entityTable) {
      throw ArgumentError('Entity type/table pair is not allowed.');
    }
    await db.transaction((txn) async {
      final operations = await txn.query(
        'outbox',
        where: 'entity_type = ? AND entity_id = ?',
        whereArgs: [entityType, entityId],
      );
      if (operations.isEmpty) {
        throw const OutboxTransitionException(
            'CREATE operation history is missing.');
      }
      final eligibleOperations = <Map<String, Object?>>[];
      for (final row in operations) {
        final status = row['status'];
        final disposition = row['remote_disposition'];
        final operationType = row['operation_type'];
        final safeDisposition = disposition == RemoteDisposition.unsent.value ||
            disposition == RemoteDisposition.confirmed.value;
        if ((status == OutboxStatus.superseded.value ||
                status == OutboxStatus.discarded.value) &&
            safeDisposition) {
          continue;
        }
        final discardable = operationType == 'CREATE' &&
            ((status == 'PENDING' && disposition == 'UNSENT') ||
                (status == 'FAILED_FATAL' && disposition == 'CONFIRMED'));
        if (!discardable) {
          throw const OutboxTransitionException(
              'Entity has an operation that vetoes CREATE discard.');
        }
        eligibleOperations.add(row);
      }
      if (eligibleOperations.isEmpty) {
        throw const OutboxTransitionException(
          'No active CREATE operation can authorize entity discard.',
        );
      }
      await _assertNoDependents(txn, entityType, entityId);
      for (final row in eligibleOperations) {
        final changed = await txn.update(
          'outbox',
          {'status': OutboxStatus.discarded.value},
          where: 'operation_id = ? AND status = ? AND remote_disposition = ?',
          whereArgs: [
            row['operation_id'],
            row['status'],
            row['remote_disposition']
          ],
        );
        if (changed != 1) {
          throw const OutboxTransitionException(
              'CREATE discard compare-and-set failed.');
        }
      }
      final deleted = await txn.delete(
        entityTable,
        where: 'id = ?',
        whereArgs: [entityId],
      );
      if (deleted != 1) {
        throw const OutboxTransitionException(
            'Local entity deletion failed during CREATE discard.');
      }
    });
  }

  Future<void> _assertNoDependents(
    DatabaseExecutor txn,
    String entityType,
    String entityId,
  ) async {
    final checks = switch (entityType) {
      'CUSTOMER' => const [
          ('equipments', 'customer_id'),
          ('service_orders', 'customer_id'),
          ('pre_acquisitions', 'customer_id'),
          ('equipment_acquisitions', 'customer_id'),
          ('payments', 'customer_id'),
        ],
      'EQUIPMENT' => const [
          ('service_orders', 'equipment_id'),
          ('pre_acquisitions', 'equipment_id'),
          ('equipment_acquisitions', 'equipment_id'),
        ],
      'SERVICE_ORDER' => const [
          ('service_order_items', 'service_order_id'),
          ('pre_acquisitions', 'service_order_id'),
          ('equipment_acquisitions', 'service_order_id'),
          ('payments', 'service_order_id'),
          ('inventory_movements', 'service_order_id'),
        ],
      'PRE_ACQUISITION' => const [
          ('equipment_acquisitions', 'client_pre_acquisition_id'),
        ],
      _ => const <(String, String)>[],
    };
    for (final (table, column) in checks) {
      final rows = await txn.query(
        table,
        columns: ['id'],
        where: '$column = ?',
        whereArgs: [entityId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        throw OutboxTransitionException(
            '$entityType has dependent rows in $table.');
      }
    }
    final commandTypes = switch (entityType) {
      'SERVICE_ORDER' => const [
          'SERVICE_ORDER_QUOTE_PUBLISH',
          'SERVICE_ORDER_QUOTE_REVISE',
          'SERVICE_ORDER_RESUME_APPROVED_SCOPE',
          'SERVICE_ORDER_MARK_READY',
          'SERVICE_ORDER_MARK_DELIVERED',
          'CUSTOMER_QUOTE_DECISION',
          'PAYMENT_CREATE',
        ],
      'PRE_ACQUISITION' => const ['EQUIPMENT_ACQUISITION_CREATE'],
      _ => const <String>[],
    };
    if (commandTypes.isNotEmpty) {
      final intents = await txn.query(
        'command_intents',
        columns: ['operation_id'],
        where:
            'target_id = ? AND lifecycle_state IN (?, ?, ?) AND command_type IN (${List.filled(commandTypes.length, '?').join(',')})',
        whereArgs: [
          entityId,
          'PENDING',
          'SENDING',
          'UNKNOWN',
          ...commandTypes,
        ],
        limit: 1,
      );
      if (intents.isNotEmpty) {
        throw OutboxTransitionException(
            '$entityType has unresolved command intents targeting it.');
      }
    }
  }
}
