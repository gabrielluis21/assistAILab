import 'package:sqflite/sqflite.dart';
import '../../core/database/sqlite_database.dart';
import 'part_entity.dart';

abstract class PartRepository {
  Future<List<PartEntity>> listAll({DatabaseExecutor? executor});
  Future<PartEntity?> findById(String id, {DatabaseExecutor? executor});
  Future<void> upsert(PartEntity part, {DatabaseExecutor? executor});
  Future<void> delete(String id, {DatabaseExecutor? executor});
}

class PartLocalDataSource implements PartRepository {
  @override
  Future<List<PartEntity>> listAll({DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps = await db.query('parts', orderBy: 'name ASC');
    return maps.map(PartEntity.fromMap).toList();
  }

  @override
  Future<PartEntity?> findById(String id, {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    final maps = await db.query('parts', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return PartEntity.fromMap(maps.first);
  }

  @override
  Future<void> upsert(PartEntity part, {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'parts',
      part.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id, {DatabaseExecutor? executor}) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.delete('parts', where: 'id = ?', whereArgs: [id]);
  }
}
