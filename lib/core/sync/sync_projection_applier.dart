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
    for (final table in const [
      'service_order_items',
      'service_orders',
      'payments',
      'equipments',
      'customers',
    ]) {
      await db.delete(table);
    }
    for (final record in records) {
      await applyRecord(db, record);
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
      if (entityType == 'SERVICE_ORDER') {
        await _assertNoPendingServiceOrderMutation(db, entityId);
      }
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
  ) async {
    final entityType = _requiredString(record, 'entityType').toUpperCase();
    final entityId = _requiredString(record, 'entityId');
    final data = _requiredMap(record['data']);
    if (data['id'] != entityId) {
      throw const SyncProjectionException('SYNC_ENTITY_ID_MISMATCH');
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
    await _assertNoPendingServiceOrderMutation(db, entityId);
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

  /// A remote snapshot is never allowed to erase a local Service Order or item
  /// mutation that has not reached the terminal SYNCED state. Throwing keeps
  /// the surrounding Sync/command transaction atomic and lets the existing
  /// Outbox + Sync cycle establish precedence; no retry policy is introduced.
  static Future<void> _assertNoPendingServiceOrderMutation(
    DatabaseExecutor db,
    String serviceOrderId,
  ) async {
    final rows = await db.query(
      'outbox',
      columns: ['entity_type', 'entity_id', 'payload', 'status'],
      where: 'status <> ? AND entity_type IN (?, ?)',
      whereArgs: ['SYNCED', 'SERVICE_ORDER', 'SERVICE_ORDER_ITEM'],
    );
    for (final row in rows) {
      final type = (row['entity_type'] as String).toUpperCase();
      if (type == 'SERVICE_ORDER' && row['entity_id'] == serviceOrderId) {
        throw const SyncProjectionException('SYNC_LOCAL_MUTATION_PENDING');
      }
      if (type != 'SERVICE_ORDER_ITEM') continue;
      final rawPayload = row['payload'];
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
      if (parentId == serviceOrderId) {
        throw const SyncProjectionException('SYNC_LOCAL_MUTATION_PENDING');
      }
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
