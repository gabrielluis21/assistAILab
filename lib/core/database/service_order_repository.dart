import 'package:sqflite/sqflite.dart';
import '../database/sqlite_database.dart';
import '../../features/service_orders/service_order_entity.dart';

abstract class ServiceOrderRepository {
  Future<List<ServiceOrderEntity>> listAll({
    DatabaseExecutor? executor,
  });

  Future<List<ServiceOrderEntity>> listByCustomerId(
    String customerId, {
    DatabaseExecutor? executor,
  });

  Future<ServiceOrderEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  });

  Future<void> upsert(
    ServiceOrderEntity order, {
    DatabaseExecutor? executor,
  });

  Future<void> updateStatus(
    String id,
    ServiceOrderStatusEnum newStatus, {
    DatabaseExecutor? executor,
  });

  Future<void> delete(
    String id, {
    DatabaseExecutor? executor,
  });
}

class ServiceOrderLocalDataSource implements ServiceOrderRepository {
  @override
  Future<List<ServiceOrderEntity>> listAll({DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps = await db.query('service_orders', orderBy: 'updated_at DESC');
    return maps.map(ServiceOrderEntity.fromMap).toList();
  }

  @override
  Future<ServiceOrderEntity?> findById(String id,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps =
        await db.query('service_orders', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return ServiceOrderEntity.fromMap(maps.first);
  }

  @override
  Future<void> upsert(ServiceOrderEntity order,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'service_orders',
      order.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> updateStatus(String id, ServiceOrderStatusEnum newStatus,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.update(
      'service_orders',
      {
        'status': newStatus.toDbString(),
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.delete('service_orders', where: 'id = ?', whereArgs: [id]);
  }

  @override
Future<List<ServiceOrderEntity>> listByCustomerId(
  String customerId, {
  DatabaseExecutor? executor,
}) async {
  final db = executor ?? await SqliteDatabase.instance;

  final maps = await db.query(
    'service_orders',
    where: 'customer_id = ?',
    whereArgs: [customerId],
    orderBy: 'updated_at DESC',
  );

  return maps
      .map(ServiceOrderEntity.fromMap)
      .toList();
}
}
