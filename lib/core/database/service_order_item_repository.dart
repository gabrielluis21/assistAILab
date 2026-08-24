import 'package:sqflite/sqflite.dart';
import 'sqlite_database.dart';
import '../../features/service_orders/service_order_item_entity.dart';

abstract class ServiceOrderItemRepository {
  Future<List<ServiceOrderItemEntity>> listByOrder(String serviceOrderId);
  Future<void> upsert(ServiceOrderItemEntity item);
  Future<void> delete(String id);
}

class ServiceOrderItemLocalDataSource implements ServiceOrderItemRepository {
  @override
  Future<List<ServiceOrderItemEntity>> listByOrder(
      String serviceOrderId) async {
    final db = await SqliteDatabase.instance;
    final maps = await db.query(
      'service_order_items',
      where: 'service_order_id = ?',
      whereArgs: [serviceOrderId],
      orderBy: 'updated_at ASC',
    );
    return maps.map(ServiceOrderItemEntity.fromMap).toList();
  }

  @override
  Future<void> upsert(ServiceOrderItemEntity item) async {
    final db = await SqliteDatabase.instance;
    await db.insert(
      'service_order_items',
      item.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id) async {
    final db = await SqliteDatabase.instance;
    await db.delete('service_order_items', where: 'id = ?', whereArgs: [id]);
  }
}
