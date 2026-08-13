import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'payment_entity.dart';
import 'payment_repository.dart';
import '../../core/database/outbox_dao.dart';
import '../customers/customers_provider.dart' show outboxDaoProvider;

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => PaymentLocalDataSource(),
);

// Dashboard summary data
class FinanceSummary {
  final double totalRevenue;
  final double monthRevenue;
  final double pendingAmount;
  final int totalPayments;
  final int pendingPayments;
  final Map<PaymentMethod, double> revenueByMethod;

  const FinanceSummary({
    required this.totalRevenue,
    required this.monthRevenue,
    required this.pendingAmount,
    required this.totalPayments,
    required this.pendingPayments,
    required this.revenueByMethod,
  });
}

// Main payments list provider
class PaymentsNotifier extends AsyncNotifier<List<PaymentEntity>> {
  @override
  Future<List<PaymentEntity>> build() => _load();

  Future<List<PaymentEntity>> _load() =>
      ref.read(paymentRepositoryProvider).listAll();

  Future<void> createPayment({
    required String serviceOrderId,
    required String customerId,
    required double amount,
    required PaymentMethod method,
    String? notes,
  }) async {
    const uuid = Uuid();
    final now = DateTime.now().toIso8601String();
    final payment = PaymentEntity(
      id: uuid.v4(),
      serviceOrderId: serviceOrderId,
      customerId: customerId,
      amount: amount,
      method: method,
      status: PaymentStatus.pending,
      notes: notes,
      createdAt: now,
      updatedAt: now,
    );

    final repo = ref.read(paymentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);

    await repo.upsert(payment);

    await outbox.insert(OutboxItem(
      operationId: uuid.v4(),
      entityType: 'PAYMENT',
      entityId: payment.id,
      operationType: 'CREATE',
      payload: payment.toMap(),
      createdAt: now,
    ));

    state = AsyncData(await _load());
  }

  Future<void> confirmPayment(String id) async {
    final repo = ref.read(paymentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);
    final now = DateTime.now().toIso8601String();

    await repo.updateStatus(id, PaymentStatus.confirmed, paidAt: now);

    await outbox.insert(OutboxItem(
      operationId: const Uuid().v4(),
      entityType: 'PAYMENT',
      entityId: id,
      operationType: 'UPDATE',
      payload: {'id': id, 'status': PaymentStatus.confirmed.toDbString(), 'paid_at': now},
      createdAt: now,
    ));

    state = AsyncData(await _load());
  }

  Future<void> cancelPayment(String id) async {
    final repo = ref.read(paymentRepositoryProvider);
    final outbox = ref.read(outboxDaoProvider);
    final now = DateTime.now().toIso8601String();

    await repo.updateStatus(id, PaymentStatus.cancelled);

    await outbox.insert(OutboxItem(
      operationId: const Uuid().v4(),
      entityType: 'PAYMENT',
      entityId: id,
      operationType: 'UPDATE',
      payload: {'id': id, 'status': PaymentStatus.cancelled.toDbString()},
      createdAt: now,
    ));

    state = AsyncData(await _load());
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = AsyncData(await _load());
  }
}

final paymentsProvider =
    AsyncNotifierProvider<PaymentsNotifier, List<PaymentEntity>>(
  PaymentsNotifier.new,
);

// Finance summary provider
final financeSummaryProvider = FutureProvider<FinanceSummary>((ref) async {
  final payments = await ref.watch(paymentsProvider.future);
  final repo = ref.read(paymentRepositoryProvider);

  final totalRevenue = await repo.totalRevenue(statusFilter: PaymentStatus.confirmed);
  final monthRevenue = await repo.revenueThisMonth();
  final pendingAmount = await repo.totalRevenue(statusFilter: PaymentStatus.pending);

  final pendingPayments = payments.where((p) => p.status == PaymentStatus.pending).length;

  // Revenue by method (confirmed only)
  final confirmedPayments = payments.where((p) => p.status == PaymentStatus.confirmed);
  final Map<PaymentMethod, double> revenueByMethod = {};
  for (final p in confirmedPayments) {
    revenueByMethod[p.method] = (revenueByMethod[p.method] ?? 0.0) + p.amount;
  }

  return FinanceSummary(
    totalRevenue: totalRevenue,
    monthRevenue: monthRevenue,
    pendingAmount: pendingAmount,
    totalPayments: payments.length,
    pendingPayments: pendingPayments,
    revenueByMethod: revenueByMethod,
  );
});
