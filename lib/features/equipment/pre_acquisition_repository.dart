import 'package:sqflite/sqflite.dart';

import '../../core/database/sqlite_database.dart';
import 'pre_acquisition_entity.dart';

abstract class PreAcquisitionRepository {
  Future<List<PreAcquisitionEntity>> listAll({DatabaseExecutor? executor});

  Future<PreAcquisitionEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  });

  Future<void> insert(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  });

  Future<void> update(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  });
}

class PreAcquisitionLocalDataSource implements PreAcquisitionRepository {
  @override
  Future<List<PreAcquisitionEntity>> listAll({
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final rows = await db.query(
      'pre_acquisitions',
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(PreAcquisitionEntity.fromMap).toList(growable: false);
  }

  @override
  Future<PreAcquisitionEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final rows = await db.query(
      'pre_acquisitions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PreAcquisitionEntity.fromMap(rows.single);
  }

  @override
  Future<void> insert(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'pre_acquisitions',
      preAcquisition.toMap(),
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  @override
  Future<void> update(
    PreAcquisitionEntity preAcquisition, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final count = await db.update(
      'pre_acquisitions',
      preAcquisition.toMap(),
      where: 'id = ?',
      whereArgs: [preAcquisition.id],
    );
    if (count != 1) {
      throw StateError('PreAcquisition does not exist in the current scope.');
    }
  }
}
