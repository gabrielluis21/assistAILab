import 'package:sqflite/sqflite.dart';
import 'payment_entity.dart';
import '../../core/money/money_minor.dart';

abstract class PaymentRepository {
  Future<List<PaymentEntity>> listAll({required DatabaseExecutor executor});
  Future<List<PaymentEntity>> listByServiceOrder(
    String serviceOrderId, {
    required DatabaseExecutor executor,
  });
  Future<List<PaymentEntity>> listByCustomer(
    String customerId, {
    required DatabaseExecutor executor,
  });
  Future<PaymentEntity?> findById(
    String id, {
    required DatabaseExecutor executor,
  });
  Future<void> upsert(
    PaymentEntity payment, {
    required DatabaseExecutor executor,
  });
  Future<void> updateStatus(
    String id,
    PaymentStatus status, {
    String? paidAt,
    required DatabaseExecutor executor,
  });
  Future<void> deleteById(
    String id, {
    required DatabaseExecutor executor,
  });
  Future<MoneyMinor> totalRevenue({
    PaymentStatus? statusFilter,
    required DatabaseExecutor executor,
  });
  Future<MoneyMinor> revenueThisMonth({
    required DatabaseExecutor executor,
  });
}

class PaymentLocalDataSource implements PaymentRepository {
  @override
  Future<List<PaymentEntity>> listAll({
    required DatabaseExecutor executor,
  }) async {
    final rows = await executor.query('payments', orderBy: 'created_at DESC');
    return rows.map((r) => PaymentEntity.fromMap(r)).toList();
  }

  @override
  Future<List<PaymentEntity>> listByServiceOrder(
    String serviceOrderId, {
    required DatabaseExecutor executor,
  }) async {
    final rows = await executor.query(
      'payments',
      where: 'service_order_id = ?',
      whereArgs: [serviceOrderId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => PaymentEntity.fromMap(r)).toList();
  }

  @override
  Future<List<PaymentEntity>> listByCustomer(
    String customerId, {
    required DatabaseExecutor executor,
  }) async {
    final rows = await executor.query(
      'payments',
      where: 'customer_id = ?',
      whereArgs: [customerId],
      orderBy: 'created_at DESC',
    );
    return rows.map((r) => PaymentEntity.fromMap(r)).toList();
  }

  @override
  Future<PaymentEntity?> findById(
    String id, {
    required DatabaseExecutor executor,
  }) async {
    final rows =
        await executor.query('payments', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return PaymentEntity.fromMap(rows.first);
  }

  @override
  Future<void> upsert(
    PaymentEntity payment, {
    required DatabaseExecutor executor,
  }) async {
    await executor.insert(
      'payments',
      payment.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> updateStatus(String id, PaymentStatus status,
      {String? paidAt, required DatabaseExecutor executor}) async {
    final now = DateTime.now().toIso8601String();
    await executor.update(
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
  Future<void> deleteById(
    String id, {
    required DatabaseExecutor executor,
  }) async {
    await executor.delete('payments', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<MoneyMinor> totalRevenue({
    PaymentStatus? statusFilter,
    required DatabaseExecutor executor,
  }) async {
    final where = statusFilter != null ? 'status = ?' : null;
    final whereArgs = statusFilter != null ? [statusFilter.toDbString()] : null;
    final result = await executor.rawQuery(
      'SELECT SUM(amount_minor) as total FROM payments${where != null ? ' WHERE $where' : ''}',
      whereArgs,
    );
    final total = result.first['total'];
    return MoneyMinor.fromJson(total ?? 0);
  }

  @override
  Future<MoneyMinor> revenueThisMonth({
    required DatabaseExecutor executor,
  }) async {
    final now = DateTime.now();
    final startOfMonth = DateTime(now.year, now.month, 1).toIso8601String();
    final result = await executor.rawQuery(
      "SELECT SUM(amount_minor) as total FROM payments WHERE status = 'CONFIRMED' AND paid_at >= ?",
      [startOfMonth],
    );
    final total = result.first['total'];
    return MoneyMinor.fromJson(total ?? 0);
  }
}
