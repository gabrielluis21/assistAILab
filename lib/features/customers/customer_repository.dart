import 'package:sqflite/sqflite.dart';
import '../../core/database/sqlite_database.dart';
import 'customer_entity.dart';

abstract class CustomerRepository {
  Future<List<CustomerEntity>> listAll();
  Future<CustomerEntity?> findById(String id);
  Future<void> upsert(CustomerEntity customer);
  Future<void> delete(String id);
}

class CustomerLocalDataSource implements CustomerRepository {
  @override
  Future<List<CustomerEntity>> listAll() async {
    final db = await SqliteDatabase.instance;
    final maps = await db.query('customers', orderBy: 'name ASC');
    return maps.map(CustomerEntity.fromMap).toList();
  }

  @override
  Future<CustomerEntity?> findById(String id) async {
    final db = await SqliteDatabase.instance;
    final maps = await db.query('customers', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return CustomerEntity.fromMap(maps.first);
  }

  @override
  Future<void> upsert(CustomerEntity customer) async {
    final db = await SqliteDatabase.instance;
    await db.insert(
      'customers',
      customer.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(String id) async {
    final db = await SqliteDatabase.instance;
    await db.delete('customers', where: 'id = ?', whereArgs: [id]);
  }
}
