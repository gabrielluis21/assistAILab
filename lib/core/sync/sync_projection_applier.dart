import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../features/equipment/equipment_entity.dart';
import '../../features/finance/payment_entity.dart';
import '../../features/service_orders/service_order_entity.dart';
import '../money/money_minor.dart';

final class SyncProjectionException implements Exception {
  final String code;
  const SyncProjectionException(this.code);

  @override
  String toString() => 'SyncProjectionException($code)';
}

abstract final class SyncProjectionApplier {
  static Future<void> replaceBootstrap(
    DatabaseExecutor db,
    List<Map<String, dynamic>> records,
  ) async {
    final policy = await _ProjectionPendingMutationPolicy.forBootstrap(db);

    // A bootstrap must be able to finish before the existing Push flow runs.
    // Preserve pending aggregates in place instead of rejecting the complete
    // snapshot, which would otherwise deadlock local mutations behind the
    // bootstrap prerequisite.
    await _deleteBootstrapRowsExcept(
      db,
      table: 'service_order_items',
      identityColumn: 'service_order_id',
      protectedIds: policy.serviceOrderIds,
    );
    await _deleteBootstrapRowsExcept(
      db,
      table: 'service_orders',
      identityColumn: 'id',
      protectedIds: policy.serviceOrderIds,
    );
    await db.delete('payments');
    await _deleteBootstrapRowsExcept(
      db,
      table: 'equipments',
      identityColumn: 'id',
      protectedIds: policy.equipmentIds,
    );
    await _deleteBootstrapRowsExcept(
      db,
      table: 'customers',
      identityColumn: 'id',
      protectedIds: policy.customerIds,
    );
    for (final record in records) {
      await _applyRecord(
        db,
        record,
        policy: policy,
        preservePending: true,
      );
    }
  }

  static Future<void> applyChange(
    DatabaseExecutor db,
    Map<String, dynamic> change,
  ) async {
    final entityType = _requiredString(change, 'entityType').toUpperCase();
    final entityId = _requiredString(change, 'entityId');
    final operation = _requiredString(change, 'operationType');
    if (operation == 'DELETE') {
      final policy =
          await _ProjectionPendingMutationPolicy.forEntity(db, entityType);
      policy.assertRemoteApplicationAllowed(entityType, entityId);
      await _delete(db, entityType, entityId);
      return;
    }
    if (operation != 'CREATE' && operation != 'UPDATE') {
      throw const SyncProjectionException('SYNC_OPERATION_INVALID');
    }
    final data = _requiredMap(change['data']);
    await applyRecord(db, {
      'entityType': entityType,
      'entityId': entityId,
      'data': data,
    });
  }

  static Future<void> applyRecord(
    DatabaseExecutor db,
    Map<String, dynamic> record,
  ) {
    return _applyRecord(db, record);
  }

  static Future<void> _applyRecord(
    DatabaseExecutor db,
    Map<String, dynamic> record, {
    _ProjectionPendingMutationPolicy? policy,
    bool preservePending = false,
  }) async {
    final entityType = _requiredString(record, 'entityType').toUpperCase();
    final entityId = _requiredString(record, 'entityId');
    final data = _requiredMap(record['data']);
    if (data['id'] != entityId) {
      throw const SyncProjectionException('SYNC_ENTITY_ID_MISMATCH');
    }
    final effectivePolicy = policy ??
        await _ProjectionPendingMutationPolicy.forEntity(db, entityType);
    if (effectivePolicy.hasPendingMutation(entityType, entityId)) {
      if (preservePending) return;
      throw const SyncProjectionException('SYNC_LOCAL_MUTATION_PENDING');
    }
    switch (entityType) {
      case 'CUSTOMER':
        await db.insert(
          'customers',
          {
            'id': entityId,
            'name': _requiredString(data, 'name'),
            'document': data['document'] as String?,
            'email': data['email'] as String?,
            'phone': data['phone'] as String?,
            'address': data['address'] as String?,
            'updated_at': _requiredString(data, 'updatedAt'),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      case 'EQUIPMENT':
        await db.insert(
          'equipments',
          {
            'id': entityId,
            'customer_id': data['customerId'] as String?,
            'organization_id': data['organizationId'] as String?,
            'owner_type':
                EquipmentOwnerType.fromDbValue(data['ownerType']).wireValue,
            'organization_purpose':
                EquipmentOrganizationPurpose.fromNullableDbValue(
              data['organizationPurpose'],
            )?.wireValue,
            'type': _requiredString(data, 'type'),
            'brand': _requiredString(data, 'brand'),
            'model': _requiredString(data, 'model'),
            'serial_number': data['serialNumber'] as String?,
            'notes': data['notes'] as String?,
            'updated_at': _requiredString(data, 'updatedAt'),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      case 'SERVICE_ORDER':
        await _applyServiceOrder(db, entityId, data);
      case 'PAYMENT':
        await _applyPayment(db, entityId, data);
      default:
        throw SyncProjectionException(
            'SYNC_ENTITY_TYPE_UNSUPPORTED:$entityType');
    }
  }

  static Future<void> _applyServiceOrder(
    DatabaseExecutor db,
    String entityId,
    Map<String, dynamic> data,
  ) async {
    if (data['contractVersion'] != 2) {
      throw const SyncProjectionException('SYNC_CONTRACT_VERSION_INVALID');
    }
    final revisionText = _requiredString(data, 'projectionRevision');
    if (!RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(revisionText)) {
      throw const SyncProjectionException('SYNC_PROJECTION_REVISION_INVALID');
    }
    final revision = BigInt.parse(revisionText);
    final fingerprint = _canonicalJson(data);
    final existing = await db.query(
      'service_orders',
      columns: ['projection_revision', 'projection_fingerprint'],
      where: 'id = ?',
      whereArgs: [entityId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final oldText = existing.first['projection_revision'];
      if (oldText is! String ||
          !RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(oldText)) {
        throw const SyncProjectionException('SYNC_LOCAL_REVISION_INVALID');
      }
      final old = BigInt.parse(oldText);
      if (revision < old) return;
      if (revision == old) {
        if (existing.first['projection_fingerprint'] != fingerprint) {
          throw const SyncProjectionException('SYNC_EQUAL_REVISION_DIVERGED');
        }
        return;
      }
    }

    final total = MoneyMinor.serviceOrderFromJson(data['totalAmountMinor']);
    final rawItems = data['items'];
    if (rawItems is! List) {
      throw const SyncProjectionException('SYNC_ITEMS_MISSING');
    }
    final itemRows = <Map<String, Object?>>[];
    final lineTotals = <MoneyMinor>[];
    for (var index = 0; index < rawItems.length; index++) {
      final item = _requiredMap(rawItems[index]);
      final quantity = item['quantity'];
      if (quantity is! int || quantity < 1 || quantity > 2147483647) {
        throw const SyncProjectionException('SYNC_QUANTITY_INVALID');
      }
      final unitPrice = MoneyMinor.serviceOrderFromJson(item['unitPriceMinor']);
      final lineTotal =
          MoneyMinor.serviceOrderFromJson(item['totalPriceMinor']);
      if (unitPrice.multiplyByQuantity(
            quantity,
            maximum: MoneyMinor.serviceOrderMaximum,
          ) !=
          lineTotal) {
        throw const SyncProjectionException('SYNC_LINE_TOTAL_INVALID');
      }
      lineTotals.add(lineTotal);
      final wireId = item['id'];
      final wireParent = item['serviceOrderId'];
      if (wireId != null && wireId is! String ||
          wireParent != null && wireParent != entityId) {
        throw const SyncProjectionException('SYNC_ITEM_IDENTITY_INVALID');
      }
      itemRows.add({
        'id': wireId as String? ?? 'customer:$entityId:$index',
        'service_order_id': entityId,
        'part_id': item['partId'] as String?,
        'description': _requiredString(item, 'description'),
        'quantity': quantity,
        'unit_price_minor': unitPrice.minorUnits,
        'total_price_minor': lineTotal.minorUnits,
        'updated_at':
            item['createdAt'] as String? ?? _requiredString(data, 'updatedAt'),
      });
    }
    if (MoneyMinor.sum(
          lineTotals,
          maximum: MoneyMinor.serviceOrderMaximum,
        ) !=
        total) {
      throw const SyncProjectionException('SYNC_ORDER_TOTAL_INVALID');
    }

    await db.insert(
      'service_orders',
      {
        'id': entityId,
        'friendly_id': data['friendlyId'] as int?,
        'organization_id': data['organizationId'] as String?,
        'customer_id': data['customerId'] as String?,
        'equipment_id': _requiredString(data, 'equipmentId'),
        'technician_id': data['technicianId'] as String?,
        'status': ServiceOrderStatusExtension.fromDbString(data['status'])
            .toDbString(),
        'problem_description': _requiredString(data, 'problemDescription'),
        'diagnosis': data['diagnosis'] as String?,
        'solution': data['solution'] as String?,
        'total_amount_minor': total.minorUnits,
        'projection_revision': revisionText,
        'projection_fingerprint': fingerprint,
        'updated_at': _requiredString(data, 'updatedAt'),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await db.delete(
      'service_order_items',
      where: 'service_order_id = ?',
      whereArgs: [entityId],
    );
    for (final row in itemRows) {
      await db.insert('service_order_items', row);
    }
  }

  static Future<void> _applyPayment(
    DatabaseExecutor db,
    String entityId,
    Map<String, dynamic> data,
  ) async {
    final amount = MoneyMinor.fromJson(data['amountMinor']);
    await db.insert(
      'payments',
      {
        'id': entityId,
        'service_order_id': _requiredString(data, 'serviceOrderId'),
        'customer_id': _requiredString(data, 'customerId'),
        'amount_minor': amount.minorUnits,
        'method':
            PaymentMethodExtension.fromDbString(data['method']).toDbString(),
        'status':
            PaymentStatusExtension.fromDbString(data['status']).toDbString(),
        'notes': data['notes'] as String?,
        'paid_at': data['paidAt'] as String?,
        'created_at': _requiredString(data, 'createdAt'),
        'updated_at': _requiredString(data, 'updatedAt'),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> _delete(
    DatabaseExecutor db,
    String entityType,
    String entityId,
  ) async {
    switch (entityType) {
      case 'CUSTOMER':
        await db.delete('customers', where: 'id = ?', whereArgs: [entityId]);
      case 'EQUIPMENT':
        await db.delete('equipments', where: 'id = ?', whereArgs: [entityId]);
      case 'SERVICE_ORDER':
        await db.delete(
          'service_order_items',
          where: 'service_order_id = ?',
          whereArgs: [entityId],
        );
        await db.delete(
          'service_orders',
          where: 'id = ?',
          whereArgs: [entityId],
        );
      case 'PAYMENT':
        await db.delete('payments', where: 'id = ?', whereArgs: [entityId]);
      default:
        throw SyncProjectionException(
            'SYNC_ENTITY_TYPE_UNSUPPORTED:$entityType');
    }
  }

  static Future<void> _deleteBootstrapRowsExcept(
    DatabaseExecutor db, {
    required String table,
    required String identityColumn,
    required Set<String> protectedIds,
  }) async {
    if (protectedIds.isEmpty) {
      await db.delete(table);
      return;
    }

    final rows = await db.query(table, columns: [identityColumn]);
    final deletableIds = rows
        .map((row) => row[identityColumn])
        .whereType<String>()
        .where((id) => !protectedIds.contains(id))
        .toSet()
        .toList(growable: false);

    // Stay below common SQLite bind limits without introducing a schema or
    // temporary-table protocol solely for bootstrap replacement.
    const chunkSize = 400;
    for (var start = 0; start < deletableIds.length; start += chunkSize) {
      final end = (start + chunkSize < deletableIds.length)
          ? start + chunkSize
          : deletableIds.length;
      final chunk = deletableIds.sublist(start, end);
      await db.delete(
        table,
        where:
            '$identityColumn IN (${List.filled(chunk.length, '?').join(',')})',
        whereArgs: chunk,
      );
    }
  }

  static Map<String, dynamic> _requiredMap(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const SyncProjectionException('SYNC_OBJECT_REQUIRED');
    }
    return value;
  }

  static String _requiredString(Map<String, dynamic> map, String field) {
    final value = map[field];
    if (value is! String || value.isEmpty) {
      throw SyncProjectionException('SYNC_FIELD_REQUIRED:$field');
    }
    return value;
  }

  static String _canonicalJson(Object? value) => jsonEncode(_canonical(value));

  static Object? _canonical(Object? value) {
    if (value is List) return value.map(_canonical).toList(growable: false);
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    return value;
  }
}

/// Central policy for remote projection application while local mutations are
/// still authoritative in the Outbox.
///
/// `status <> SYNCED` intentionally preserves the existing Service Order
/// behavior, including FAILED/CONFLICT/REQUIRES_ATTENTION as unresolved. The
/// policy does not pick a winner or remove/mutate Outbox rows.
final class _ProjectionPendingMutationPolicy {
  final Set<String> customerIds;
  final Set<String> equipmentIds;
  final Set<String> serviceOrderIds;

  const _ProjectionPendingMutationPolicy({
    required this.customerIds,
    required this.equipmentIds,
    required this.serviceOrderIds,
  });

  static Future<_ProjectionPendingMutationPolicy> forBootstrap(
    DatabaseExecutor db,
  ) {
    return _load(
      db,
      includeCustomer: true,
      includeEquipment: true,
      includeServiceOrder: true,
    );
  }

  static Future<_ProjectionPendingMutationPolicy> forEntity(
    DatabaseExecutor db,
    String entityType,
  ) {
    return _load(
      db,
      includeCustomer: entityType == 'CUSTOMER',
      includeEquipment: entityType == 'EQUIPMENT',
      includeServiceOrder: entityType == 'SERVICE_ORDER',
    );
  }

  static Future<_ProjectionPendingMutationPolicy> _load(
    DatabaseExecutor db, {
    required bool includeCustomer,
    required bool includeEquipment,
    required bool includeServiceOrder,
  }) async {
    final includedTypes = <String>[
      if (includeCustomer) 'CUSTOMER',
      if (includeEquipment) 'EQUIPMENT',
      if (includeServiceOrder) ...['SERVICE_ORDER', 'SERVICE_ORDER_ITEM'],
    ];
    if (includedTypes.isEmpty) {
      return const _ProjectionPendingMutationPolicy(
        customerIds: {},
        equipmentIds: {},
        serviceOrderIds: {},
      );
    }

    final rows = await db.query(
      'outbox',
      columns: ['entity_type', 'entity_id', 'payload'],
      where:
          'status <> ? AND UPPER(entity_type) IN (${List.filled(includedTypes.length, '?').join(',')})',
      whereArgs: ['SYNCED', ...includedTypes],
    );
    final customerIds = <String>{};
    final equipmentIds = <String>{};
    final serviceOrderIds = <String>{};
    for (final row in rows) {
      final rawType = row['entity_type'];
      final entityId = row['entity_id'];
      if (rawType is! String || entityId is! String || entityId.isEmpty) {
        throw const SyncProjectionException('SYNC_LOCAL_OUTBOX_INVALID');
      }
      switch (rawType.toUpperCase()) {
        case 'CUSTOMER':
          customerIds.add(entityId);
        case 'EQUIPMENT':
          equipmentIds.add(entityId);
        case 'SERVICE_ORDER':
          serviceOrderIds.add(entityId);
        case 'SERVICE_ORDER_ITEM':
          serviceOrderIds.add(_serviceOrderParentId(row['payload']));
      }
    }
    return _ProjectionPendingMutationPolicy(
      customerIds: customerIds,
      equipmentIds: equipmentIds,
      serviceOrderIds: serviceOrderIds,
    );
  }

  bool hasPendingMutation(String entityType, String entityId) {
    return switch (entityType) {
      'CUSTOMER' => customerIds.contains(entityId),
      'EQUIPMENT' => equipmentIds.contains(entityId),
      'SERVICE_ORDER' => serviceOrderIds.contains(entityId),
      _ => false,
    };
  }

  void assertRemoteApplicationAllowed(String entityType, String entityId) {
    if (hasPendingMutation(entityType, entityId)) {
      throw const SyncProjectionException('SYNC_LOCAL_MUTATION_PENDING');
    }
  }

  static String _serviceOrderParentId(Object? rawPayload) {
    if (rawPayload is! String) {
      throw const SyncProjectionException('SYNC_LOCAL_OUTBOX_INVALID');
    }
    Object? decoded;
    try {
      decoded = jsonDecode(rawPayload);
    } catch (_) {
      throw const SyncProjectionException('SYNC_LOCAL_OUTBOX_INVALID');
    }
    if (decoded is! Map) {
      throw const SyncProjectionException('SYNC_LOCAL_OUTBOX_INVALID');
    }
    final parentId = decoded['serviceOrderId'];
    if (parentId is! String || parentId.isEmpty) {
      throw const SyncProjectionException('SYNC_LOCAL_OUTBOX_INVALID');
    }
    return parentId;
  }
}
