import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/commands/command_intent.dart';
import '../../core/database/auth_scoped_database_manager.dart';
import '../../core/money/money_minor.dart';
import '../auth/application/auth_provider.dart';
import '../auth/application/session_api_client.dart';
import '../auth/domain/entities/session_state.dart';
import 'payment_command_gateway.dart';
import 'payment_command_intent.dart';
import 'payment_entity.dart';
import 'payment_repository.dart';

typedef _PaymentSessionBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

final paymentRepositoryProvider = Provider<PaymentRepository>(
  (ref) => PaymentLocalDataSource(),
);

final paymentCommandIntentRepositoryProvider =
    Provider<CommandIntentRepository>(
  (ref) => CommandIntentLocalDataSource(),
);

final paymentCommandGatewayProvider = Provider<PaymentCommandGateway>(
  (ref) => PaymentHttpCommandGateway(ref.watch(sessionApiClientProvider)),
);

final paymentDatabaseManagerProvider = Provider<AuthScopedDatabaseManager>(
  (ref) => AuthScopedDatabaseManager.instance,
);

final paymentOperationIdFactoryProvider = Provider<String Function()>(
  (ref) => const Uuid().v4,
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

class PaymentsNotifier extends AutoDisposeAsyncNotifier<List<PaymentEntity>> {
  @override
  Future<List<PaymentEntity>> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    ref.watch(isOnlineSessionProvider);
    final binding = _captureBinding(sessionKey);
    _ensureBindingCurrent(binding);
    await ref
        .read(paymentCommandIntentRepositoryProvider)
        .recoverInterruptedSending(
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
    return _load(binding);
  }

  Future<List<PaymentEntity>> _load(_PaymentSessionBinding binding) async {
    final repository = ref.read(paymentRepositoryProvider);
    final database = binding.databaseHandle.database;
    if (!ref.read(isOnlineSessionProvider)) {
      final local = await repository.listAll(executor: database);
      _ensureBindingCurrent(binding);
      return local;
    }

    final authoritative =
        await ref.read(paymentCommandGatewayProvider).listAll();
    _ensureBindingCurrent(binding);
    final authoritativeIds = authoritative.map((payment) => payment.id).toSet();
    await database.transaction((txn) async {
      _ensureBindingCurrent(binding);
      final cached = await repository.listAll(executor: txn);
      for (final payment in authoritative) {
        _ensureBindingCurrent(binding);
        await repository.upsert(payment, executor: txn);
      }
      for (final payment in cached) {
        if (!authoritativeIds.contains(payment.id)) {
          _ensureBindingCurrent(binding);
          await repository.deleteById(payment.id, executor: txn);
        }
      }
    });
    _ensureBindingCurrent(binding);
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
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    await _executor(binding).create(
      serviceOrderId: serviceOrderId,
      amount: amount,
      method: method,
      notes: notes,
    );
    _ensureBindingCurrent(binding);
    final payments = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(payments);
  }

  Future<void> confirmPayment(String id) =>
      _transition(id, PaymentStatus.confirmed);

  Future<void> cancelPayment(String id) =>
      _transition(id, PaymentStatus.cancelled);

  Future<void> _transition(String id, PaymentStatus requested) async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    await _executor(binding).transition(
      paymentId: id,
      status: requested,
    );
    _ensureBindingCurrent(binding);
    final payments = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(payments);
  }

  Future<void> refresh() async {
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();
    final payments = await _load(binding);
    _ensureBindingCurrent(binding);
    state = AsyncData(payments);
  }

  PaymentCommandIntentExecutor _executor(_PaymentSessionBinding binding) {
    return PaymentCommandIntentExecutor(
      gateway: ref.read(paymentCommandGatewayProvider),
      paymentRepository: ref.read(paymentRepositoryProvider),
      intentRepository: ref.read(paymentCommandIntentRepositoryProvider),
      database: binding.databaseHandle.database,
      isBindingCurrent: () => _isBindingCurrent(binding),
      operationIdFactory: ref.read(paymentOperationIdFactoryProvider),
    );
  }

  _PaymentSessionBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null) {
      throw StateError('An authenticated session is required for payments.');
    }
    final manager = ref.read(paymentDatabaseManagerProvider);
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated Payment session.',
      );
    }
    return (sessionKey: sessionKey, databaseHandle: handle);
  }

  bool _isBindingCurrent(_PaymentSessionBinding binding) {
    final manager = ref.read(paymentDatabaseManagerProvider);
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        manager.isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_PaymentSessionBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError('The Payment operation belongs to a stale session.');
    }
  }
}

final paymentsProvider =
    AutoDisposeAsyncNotifierProvider<PaymentsNotifier, List<PaymentEntity>>(
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
  final sessionKey = ref.watch(authenticatedSessionKeyProvider);
  if (sessionKey == null) {
    throw StateError('An authenticated session is required for Finance.');
  }
  final manager = ref.watch(paymentDatabaseManagerProvider);
  final handle = manager.currentHandle;
  if (handle == null ||
      handle.authScope != sessionKey.scope ||
      handle.sessionGeneration != sessionKey.sessionGeneration ||
      !manager.isCurrentHandle(handle)) {
    throw StateError('Finance has no current authenticated database binding.');
  }

  final payments = await ref.watch(paymentsProvider.future);
  if (ref.read(authenticatedSessionKeyProvider) != sessionKey ||
      !manager.isCurrentHandle(handle)) {
    throw StateError('Finance fetch was superseded by another session.');
  }
  final repository = ref.read(paymentRepositoryProvider);
  final totalRevenue = await repository.totalRevenue(
    statusFilter: PaymentStatus.confirmed,
    executor: handle.database,
  );
  final monthRevenue =
      await repository.revenueThisMonth(executor: handle.database);
  final pendingAmount = await repository.totalRevenue(
    statusFilter: PaymentStatus.pending,
    executor: handle.database,
  );
  if (ref.read(authenticatedSessionKeyProvider) != sessionKey ||
      !manager.isCurrentHandle(handle)) {
    throw StateError('Finance aggregation belongs to a stale session.');
  }
  final pendingPayments = payments
      .where((payment) => payment.status == PaymentStatus.pending)
      .length;

  return FinanceSummary(
    totalRevenue: totalRevenue,
    monthRevenue: monthRevenue,
    pendingAmount: pendingAmount,
    totalPayments: payments.length,
    pendingPayments: pendingPayments,
    revenueByMethod: aggregateConfirmedRevenueByMethod(payments),
  );
});
