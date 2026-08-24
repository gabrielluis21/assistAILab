import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import '../network/api_client.dart';
import '../database/sqlite_database.dart';
import '../database/outbox_dao.dart';

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

  Future<String?> getLocalCursor() async {
    final db = await SqliteDatabase.instance;
    final res = await db
        .query('sync_metadata', where: 'key = ?', whereArgs: ['last_cursor']);
    if (res.isNotEmpty) {
      return res.first['value'] as String?;
    }
    return null;
  }

  Future<void> saveLocalCursor(String cursor) async {
    final db = await SqliteDatabase.instance;
    await db.insert(
      'sync_metadata',
      {'key': 'last_cursor', 'value': cursor},
      conflictAlgorithm: ConflictAlgorithm.replace,
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
  Future<SyncPushSummary> pushPendingOutbox({int batchSize = 20}) async {
    final pendingEntries = await outboxDao.getPendingEntries(limit: batchSize);
    if (pendingEntries.isEmpty) {
      return const SyncPushSummary();
    }

    final payload = {
      'entries': pendingEntries.map((e) => e.toMap()).toList(),
    };

    for (final item in pendingEntries) {
      await outboxDao.updateStatus(item.operationId, 'PROCESSING');
    }

    int synced = 0;
    int failed = 0;
    int conflict = 0;

    try {
      final response = await apiClient
          .post(
            '/sync/push',
            body: payload,
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        final results = body['results'] as List<dynamic>? ?? [];

        for (final res in results) {
          final opId = res['operationId'] as String;
          final status = res['status'] as String;
          final error = res['error'] as String?;

          if (status == 'SYNCED') {
            await outboxDao.updateStatus(opId, 'SYNCED');
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
          );
        }
        throw Exception('HTTP ${response.statusCode}: Push failed');
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

  /// Executes pull to fetch incremental server changes using cursor pagination.
  Future<SyncPullSummary> pullIncrementalChanges({int limit = 50}) async {
    int totalPulled = 0;
    String? latestCursor;
    bool hasMore = true;

    while (hasMore) {
      final cursor = latestCursor ?? await getLocalCursor();
      final cursorParam = (cursor != null && cursor.isNotEmpty)
          ? '?cursor=$cursor&limit=$limit'
          : '?limit=$limit';

      final response = await apiClient
          .get('/sync/changes$cursorParam')
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}: Pull changes failed');
      }

      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final nextCursor = body['nextCursor'] as String?;
      final changes = body['changes'] as List<dynamic>? ?? [];

      if (changes.isNotEmpty) {
        totalPulled += changes.length;
        final db = await SqliteDatabase.instance;

        await db.transaction((txn) async {
          for (final change in changes) {
            final entityType = (change['entityType'] as String).toUpperCase();
            final entityId = change['entityId'] as String;
            final opType = change['operationType'] as String;
            final data = (change['data'] as Map<String, dynamic>?) ?? {};

            if (entityType == 'CUSTOMER') {
              if (opType == 'CREATE' || opType == 'UPDATE') {
                await txn.insert(
                  'customers',
                  {
                    'id': entityId,
                    'name': data['name'] ?? '',
                    'document': data['document'],
                    'email': data['email'],
                    'phone': data['phone'],
                    'address': data['address'],
                    'updated_at': data['updated_at'] ??
                        data['updatedAt'] ??
                        DateTime.now().toIso8601String(),
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else if (opType == 'DELETE') {
                await txn.delete('customers',
                    where: 'id = ?', whereArgs: [entityId]);
              }
            } else if (entityType == 'EQUIPMENT') {
              if (opType == 'CREATE' || opType == 'UPDATE') {
                await txn.insert(
                  'equipments',
                  {
                    'id': entityId,
                    'customer_id': data['customer_id'] ?? data['customerId'],
                    'organization_id':
                        data['organization_id'] ?? data['organizationId'],
                    'owner_type':
                        data['owner_type'] ?? data['ownerType'] ?? 'CUSTOMER',
                    'organization_purpose': data['organization_purpose'] ??
                        data['organizationPurpose'],
                    'type': data['type'] ?? '',
                    'brand': data['brand'] ?? '',
                    'model': data['model'] ?? '',
                    'serial_number':
                        data['serial_number'] ?? data['serialNumber'],
                    'notes': data['notes'],
                    'updated_at': data['updated_at'] ??
                        data['updatedAt'] ??
                        DateTime.now().toIso8601String(),
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else if (opType == 'DELETE') {
                await txn.delete('equipments',
                    where: 'id = ?', whereArgs: [entityId]);
              }
            } else if (entityType == 'SERVICE_ORDER') {
              if (opType == 'CREATE' || opType == 'UPDATE') {
                await txn.insert(
                  'service_orders',
                  {
                    'id': entityId,
                    'friendly_id': data['friendly_id'] ?? data['friendlyId'],
                    'organization_id':
                        data['organization_id'] ?? data['organizationId'],
                    'customer_id': data['customer_id'] ?? data['customerId'] ?? '',
                    'equipment_id':
                        data['equipment_id'] ?? data['equipmentId'] ?? '',
                    'technician_id':
                        data['technician_id'] ?? data['technicianId'],
                    'status': data['status'] ?? 'DIAGNOSTICO',
                    'problem_description': data['problem_description'] ??
                        data['problemDescription'] ??
                        '',
                    'diagnosis': data['diagnosis'],
                    'solution': data['solution'],
                    'total_amount':
                        data['total_amount'] ?? data['totalAmount'] ?? 0.0,
                    'updated_at': data['updated_at'] ??
                        data['updatedAt'] ??
                        DateTime.now().toIso8601String(),
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else if (opType == 'DELETE') {
                await txn.delete('service_orders',
                    where: 'id = ?', whereArgs: [entityId]);
              }
            } else if (entityType == 'SERVICE_ORDER_ITEM') {
              if (opType == 'CREATE' || opType == 'UPDATE') {
                await txn.insert(
                  'service_order_items',
                  {
                    'id': entityId,
                    'service_order_id': data['service_order_id'] ??
                        data['serviceOrderId'] ??
                        '',
                    'part_id': data['part_id'] ?? data['partId'],
                    'description': data['description'] ?? '',
                    'quantity': data['quantity'] ?? 1,
                    'unit_price':
                        data['unit_price'] ?? data['unitPrice'] ?? 0.0,
                    'total_price':
                        data['total_price'] ?? data['totalPrice'] ?? 0.0,
                    'updated_at': data['updated_at'] ??
                        data['updatedAt'] ??
                        DateTime.now().toIso8601String(),
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else if (opType == 'DELETE') {
                await txn.delete('service_order_items',
                    where: 'id = ?', whereArgs: [entityId]);
              }
            } else if (entityType == 'PART') {
              if (opType == 'CREATE' || opType == 'UPDATE') {
                await txn.insert(
                  'parts',
                  {
                    'id': entityId,
                    'name': data['name'] ?? '',
                    'sku': data['sku'] ?? '',
                    'price': data['price'] ?? 0.0,
                    'cost_price':
                        data['cost_price'] ?? data['costPrice'] ?? 0.0,
                    'stock_quantity':
                        data['stock_quantity'] ?? data['stockQuantity'] ?? 0,
                    'updated_at': data['updated_at'] ??
                        data['updatedAt'] ??
                        DateTime.now().toIso8601String(),
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else if (opType == 'DELETE') {
                await txn.delete('parts',
                    where: 'id = ?', whereArgs: [entityId]);
              }
            } else if (entityType == 'PAYMENT') {
              if (opType == 'CREATE' || opType == 'UPDATE') {
                await txn.insert(
                  'payments',
                  {
                    'id': entityId,
                    'service_order_id': data['service_order_id'] ??
                        data['serviceOrderId'] ??
                        '',
                    'customer_id':
                        data['customer_id'] ?? data['customerId'] ?? '',
                    'amount': data['amount'] ?? 0.0,
                    'method': data['method'] ?? 'MONEY',
                    'status': data['status'] ?? 'PENDING',
                    'notes': data['notes'],
                    'paid_at': data['paid_at'] ?? data['paidAt'],
                    'created_at': data['created_at'] ??
                        data['createdAt'] ??
                        DateTime.now().toIso8601String(),
                    'updated_at': data['updated_at'] ??
                        data['updatedAt'] ??
                        DateTime.now().toIso8601String(),
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace,
                );
              } else if (opType == 'DELETE') {
                await txn.delete('payments',
                    where: 'id = ?', whereArgs: [entityId]);
              }
            }
          }
        });
      }

      if (nextCursor != null && nextCursor.isNotEmpty) {
        latestCursor = nextCursor;
        await saveLocalCursor(nextCursor);
      }

      // If page had fewer items than limit or no changes, we have caught up
      if (changes.length < limit || nextCursor == null || nextCursor.isEmpty) {
        hasMore = false;
      }
    }

    return SyncPullSummary(
      totalChanges: totalPulled,
      nextCursor: latestCursor,
    );
  }
}
