import 'package:sqflite/sqflite.dart';

import '../../core/database/sqlite_database.dart';
import 'equipment_acquisition_entity.dart';

abstract interface class EquipmentAcquisitionRepository {
  Future<List<EquipmentAcquisitionEntity>> listAll({
    DatabaseExecutor? executor,
  });

  Future<EquipmentAcquisitionEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  });

  Future<EquipmentAcquisitionEntity?> findByClientPreAcquisitionId(
    String clientPreAcquisitionId, {
    DatabaseExecutor? executor,
  });

  Future<void> upsert(
    EquipmentAcquisitionEntity acquisition, {
    DatabaseExecutor? executor,
  });

  Future<void> deleteAbsentFrom(
    Set<String> authoritativeIds, {
    DatabaseExecutor? executor,
  });
}

final class EquipmentAcquisitionLocalDataSource
    implements EquipmentAcquisitionRepository {
  @override
  Future<List<EquipmentAcquisitionEntity>> listAll({
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final rows = await db.query(
      'equipment_acquisitions',
      orderBy: 'created_at DESC, id DESC',
    );
    return rows.map(EquipmentAcquisitionEntity.fromMap).toList(growable: false);
  }

  @override
  Future<EquipmentAcquisitionEntity?> findById(
    String id, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final rows = await db.query(
      'equipment_acquisitions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return EquipmentAcquisitionEntity.fromMap(rows.single);
  }

  @override
  Future<EquipmentAcquisitionEntity?> findByClientPreAcquisitionId(
    String clientPreAcquisitionId, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    final rows = await db.query(
      'equipment_acquisitions',
      where: 'client_pre_acquisition_id = ?',
      whereArgs: [clientPreAcquisitionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return EquipmentAcquisitionEntity.fromMap(rows.single);
  }

  @override
  Future<void> upsert(
    EquipmentAcquisitionEntity acquisition, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    await db.insert(
      'equipment_acquisitions',
      acquisition.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> deleteAbsentFrom(
    Set<String> authoritativeIds, {
    DatabaseExecutor? executor,
  }) async {
    final db = executor ?? await SqliteDatabase.instance;
    if (authoritativeIds.isEmpty) {
      await db.delete('equipment_acquisitions');
      return;
    }
    final ids = authoritativeIds.toList(growable: false)..sort();
    final placeholders = List.filled(ids.length, '?').join(', ');
    await db.delete(
      'equipment_acquisitions',
      where: 'id NOT IN ($placeholders)',
      whereArgs: ids,
    );
  }
}
