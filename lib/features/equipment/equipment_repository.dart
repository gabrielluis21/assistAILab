import 'package:sqflite/sqflite.dart';
import '../../core/database/sqlite_database.dart';
import 'equipment_entity.dart';

abstract class EquipmentRepository {
  Future<List<EquipmentEntity>> listAll();
  Future<List<EquipmentEntity>> listByCustomer(String customerId);
  Future<EquipmentEntity?> findById(String id);
  Future<void> upsert(EquipmentEntity equipment);
  Future<void> delete(String id);
}

class EquipmentLocalDataSource implements EquipmentRepository {
  @override
  Future<List<EquipmentEntity>> listAll() async {
    final db = await SqliteDatabase.instance;
    final maps = await db.query('equipments', orderBy: 'brand ASC, model ASC');
    return maps.map(EquipmentEntity.fromMap).toList();
  }

  @override
  Future<List<EquipmentEntity>> listByCustomer(String customerId) async {
    final db = await SqliteDatabase.instance;
    final maps = await db.query(
      'equipments',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'brand ASC, model ASC',
    );
    return maps.map(EquipmentEntity.fromMap).toList();
  }

  @override
  Future<EquipmentEntity?> findById(String id) async {
    final db = await SqliteDatabase.instance;
    final maps = await db.query('equipments', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return EquipmentEntity.fromMap(maps.first);
  }

  @override
  Future<void> upsert(EquipmentEntity equipment) async {
    final db = await SqliteDatabase.instance;
    await db.insert(
      'equipments',
      equipment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id) async {
    final db = await SqliteDatabase.instance;
    await db.delete('equipments', where: 'id = ?', whereArgs: [id]);
  }
}
