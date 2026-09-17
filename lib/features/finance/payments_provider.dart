import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/money/money_minor.dart';
import '../auth/application/auth_provider.dart';
import '../auth/application/session_api_client.dart';
import 'payment_command_gateway.dart';
import 'payment_entity.dart';
import 'payment_repository.dart';

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => PaymentLocalDataSource(),
);

final paymentCommandGatewayProvider = Provider<PaymentCommandGateway>(
  (ref) => PaymentHttpCommandGateway(ref.watch(sessionApiClientProvider)),
);

class FinanceSummary {
  final MoneyMinor totalRevenue;
  final MoneyMinor monthRevenue;
  final MoneyMinor pendingAmount;
  final int totalPayments;
  final int pendingPayments;
  final Map<PaymentMethod, MoneyMinor> revenueByMethod;

  const FinanceSummary({
    required this.totalRevenue,
    required this.monthRevenue,
    required this.pendingAmount,
    required this.totalPayments,
    required this.pendingPayments,
    required this.revenueByMethod,
  });
}

class PaymentsNotifier extends AsyncNotifier<List<PaymentEntity>> {
  @override
  Future<List<PaymentEntity>> build() => _load();

  Future<List<PaymentEntity>> _load() async {
    final repository = ref.read(paymentRepositoryProvider);
    if (!ref.read(isOnlineSessionProvider)) return repository.listAll();

    final authoritative =
        await ref.read(paymentCommandGatewayProvider).listAll();
    final authoritativeIds = authoritative.map((payment) => payment.id).toSet();
    final cached = await repository.listAll();
    for (final payment in authoritative) {
      await repository.upsert(payment);
    }
    for (final payment in cached) {
      if (!authoritativeIds.contains(payment.id)) {
        await repository.deleteById(payment.id);
      }
    }
    return authoritative;
  }

  Future<void> createPayment({
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  }) async {
    if (amount.minorUnits == 0) {
      throw ArgumentError.value(amount, 'amount', 'Payment must be positive.');
    }
    final repository = ref.read(paymentRepositoryProvider);
    final coordinator = PaymentAuthorityCoordinator(
      gateway: ref.read(paymentCommandGatewayProvider),
      commit: repository.upsert,
    );
    await coordinator.create(
      operationId: const Uuid().v4(),
      serviceOrderId: serviceOrderId,
      amount: amount,
      method: method,
      notes: notes,
    );
    state = AsyncData(await _load());
  }

  Future<void> confirmPayment(String id) =>
      _transition(id, PaymentStatus.confirmed);

  Future<void> cancelPayment(String id) =>
      _transition(id, PaymentStatus.cancelled);

  Future<void> _transition(String id, PaymentStatus requested) async {
    // Do not mutate the local business status before the authoritative command
    // response returns. A failed command therefore preserves the snapshot.
    final repository = ref.read(paymentRepositoryProvider);
    final coordinator = PaymentAuthorityCoordinator(
      gateway: ref.read(paymentCommandGatewayProvider),
      commit: repository.upsert,
    );
    await coordinator.transition(
      operationId: const Uuid().v4(),
      paymentId: id,
      status: requested,
    );
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

Map<PaymentMethod, MoneyMinor> aggregateConfirmedRevenueByMethod(
  Iterable<PaymentEntity> payments,
) {
  final result = <PaymentMethod, MoneyMinor>{};
  for (final payment
      in payments.where((value) => value.status == PaymentStatus.confirmed)) {
    result[payment.method] =
        (result[payment.method] ?? MoneyMinor.zero).add(payment.amount);
  }
  return result;
}

final financeSummaryProvider = FutureProvider<FinanceSummary>((ref) async {
  final payments = await ref.watch(paymentsProvider.future);
  final repository = ref.read(paymentRepositoryProvider);
  final totalRevenue =
      await repository.totalRevenue(statusFilter: PaymentStatus.confirmed);
  final monthRevenue = await repository.revenueThisMonth();
  final pendingAmount =
      await repository.totalRevenue(statusFilter: PaymentStatus.pending);
  final pendingPayments = payments
      .where((payment) => payment.status == PaymentStatus.pending)
      .length;

  final revenueByMethod = aggregateConfirmedRevenueByMethod(payments);

  return FinanceSummary(
    totalRevenue: totalRevenue,
    monthRevenue: monthRevenue,
    pendingAmount: pendingAmount,
    totalPayments: payments.length,
    pendingPayments: pendingPayments,
    revenueByMethod: revenueByMethod,
  );
});
