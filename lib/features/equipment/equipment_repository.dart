import 'package:sqflite/sqflite.dart';
import '../../core/database/sqlite_database.dart';
import 'equipment_entity.dart';

abstract class EquipmentRepository {
  Future<List<EquipmentEntity>> listAll({DatabaseExecutor? executor});
  Future<List<EquipmentEntity>> listByCustomer(String customerId,
      {DatabaseExecutor? executor});
  Future<EquipmentEntity?> findById(String id, {DatabaseExecutor? executor});
  Future<void> upsert(EquipmentEntity equipment, {DatabaseExecutor? executor});
  Future<void> delete(String id, {DatabaseExecutor? executor});
}

class EquipmentLocalDataSource implements EquipmentRepository {
  @override
  Future<List<EquipmentEntity>> listAll({DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps = await db.query('equipments', orderBy: 'brand ASC, model ASC');
    return maps.map(EquipmentEntity.fromMap).toList();
  }

  @override
  Future<List<EquipmentEntity>> listByCustomer(String customerId,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps = await db.query(
      'equipments',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'brand ASC, model ASC',
    );
    return maps.map(EquipmentEntity.fromMap).toList();
  }

  @override
  Future<EquipmentEntity?> findById(String id,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps = await db.query('equipments', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return EquipmentEntity.fromMap(maps.first);
  }

  @override
  Future<void> upsert(EquipmentEntity equipment,
      {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'equipments',
      equipment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.delete('equipments', where: 'id = ?', whereArgs: [id]);
  }
}
