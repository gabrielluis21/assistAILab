import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'sqlite_database.dart';

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
  final String status; // PENDING, PROCESSING, SYNCED, FAILED, CONFLICT

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
  });

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
    );
  }
}

class OutboxDao {
  Future<void> insert(OutboxItem item) async {
    final db = await SqliteDatabase.instance;
    await db.insert(
      'outbox',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<OutboxItem>> getPendingEntries({int limit = 20}) async {
    final db = await SqliteDatabase.instance;
    final nowIso = DateTime.now().toIso8601String();
    final maps = await db.query(
      'outbox',
      where: '(status = ? OR status = ?) AND (next_retry_at IS NULL OR next_retry_at <= ?)',
      whereArgs: ['PENDING', 'FAILED', nowIso],
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return maps.map((m) => OutboxItem.fromMap(m)).toList();
  }

  Future<void> updateStatus(
    String operationId,
    String status, {
    int? attemptCount,
    String? lastAttemptAt,
    String? nextRetryAt,
    String? lastError,
  }) async {
    final db = await SqliteDatabase.instance;
    final data = <String, dynamic>{'status': status};
    if (attemptCount != null) {
      data['attempt_count'] = attemptCount;
    }
    if (lastAttemptAt != null) {
      data['last_attempt_at'] = lastAttemptAt;
    }
    if (nextRetryAt != null) {
      data['next_retry_at'] = nextRetryAt;
    }
    if (lastError != null) {
      data['last_error'] = lastError;
    }
    await db.update(
      'outbox',
      data,
      where: 'operation_id = ?',
      whereArgs: [operationId],
    );
  }

  Future<void> delete(String operationId) async {
    final db = await SqliteDatabase.instance;
    await db.delete(
      'outbox',
      where: 'operation_id = ?',
      whereArgs: [operationId],
    );
  }
}
