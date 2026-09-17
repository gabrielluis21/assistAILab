import 'package:sqflite/sqflite.dart';
import '../../core/database/sqlite_database.dart';
import 'payment_entity.dart';
import '../../core/money/money_minor.dart';

abstract class PaymentRepository {
  Future<List<PaymentEntity>> listAll();
  Future<List<PaymentEntity>> listByServiceOrder(String serviceOrderId);
  Future<List<PaymentEntity>> listByCustomer(String customerId);
  Future<PaymentEntity?> findById(String id);
  Future<void> upsert(PaymentEntity payment);
  Future<void> updateStatus(String id, PaymentStatus status, {String? paidAt});
  Future<void> deleteById(String id);
  Future<MoneyMinor> totalRevenue({PaymentStatus? statusFilter});
  Future<MoneyMinor> revenueThisMonth();
}

class PaymentLocalDataSource implements PaymentRepository {
  Future<Database> get _db async => SqliteDatabase.instance;

  @override
  Future<List<PaymentEntity>> listAll() async {
    final db = await _db;
    final rows = await db.query('payments', orderBy: 'created_at DESC');
    return rows.map((r) => PaymentEntity.fromMap(r)).toList();
  }

  @override
  Future<List<PaymentEntity>> listByServiceOrder(String serviceOrderId) async {
    final db = await _db;
    final rows = await db.query(
      'payments',
      where: 'service_order_id = ?',
      whereArgs: [serviceOrderId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => PaymentEntity.fromMap(r)).toList();
  }

  @override
  Future<List<PaymentEntity>> listByCustomer(String customerId) async {
    final db = await _db;
    final rows = await db.query(
      'payments',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => PaymentEntity.fromMap(r)).toList();
  }

  @override
  Future<PaymentEntity?> findById(String id) async {
    final db = await _db;
    final rows = await db.query('payments', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return PaymentEntity.fromMap(rows.first);
  }

  @override
  Future<void> upsert(PaymentEntity payment) async {
    final db = await _db;
    await db.insert(
      'payments',
      payment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> updateStatus(String id, PaymentStatus status,
      {String? paidAt}) async {
    final db = await _db;
    final now = DateTime.now().toIso8601String();
    await db.update(
      'payments',
      {
        'status': status.toDbString(),
        'paid_at': paidAt ?? (status == PaymentStatus.confirmed ? now : null),
        'updated_at': now,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> deleteById(String id) async {
    final db = await _db;
    await db.delete('payments', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<MoneyMinor> totalRevenue({PaymentStatus? statusFilter}) async {
    final db = await _db;
    final where = statusFilter != null ? 'status = ?' : null;
    final whereArgs = statusFilter != null ? [statusFilter.toDbString()] : null;
    final result = await db.rawQuery(
      'SELECT SUM(amount_minor) as total FROM payments${where != null ? ' WHERE $where' : ''}',
      whereArgs,
    );
    final total = result.first['total'];
    return MoneyMinor.fromJson(total ?? 0);
  }

  @override
  Future<MoneyMinor> revenueThisMonth() async {
    final db = await _db;
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1).toIso8601String();
    final result = await db.rawQuery(
      "SELECT SUM(amount_minor) as total FROM payments WHERE status = 'CONFIRMED' AND paid_at >= ?",
      [startOfMonth],
    );
    final total = result.first['total'];
    return MoneyMinor.fromJson(total ?? 0);
  }
}
