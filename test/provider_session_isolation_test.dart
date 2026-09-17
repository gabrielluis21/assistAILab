import 'dart:async';

import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/entities/session_state.dart';
import 'package:assistailab/features/customers/customer_entity.dart';
import 'package:assistailab/features/customers/customers_provider.dart';
import 'package:assistailab/features/dashboard/dashboard_provider.dart';
import 'package:assistailab/features/equipment/equipment_entity.dart';
import 'package:assistailab/features/equipment/equipments_provider.dart';
import 'package:assistailab/features/finance/payments_provider.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/service_orders_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _scopeA =
    ProfessionalAuthScope(userId: 'user-a', organizationId: 'org-a');
const _scopeB =
    ProfessionalAuthScope(userId: 'user-b', organizationId: 'org-b');
const _keyA = AuthenticatedSessionKey(scope: _scopeA, sessionGeneration: 1);
const _keyB = AuthenticatedSessionKey(scope: _scopeB, sessionGeneration: 2);

final _controlledSessionKeyProvider =
    StateProvider<AuthenticatedSessionKey>((ref) => _keyA);

void main() {
  test(
    'provider fetch A -> session B -> late A never publishes into B',
    () async {
      final aEntered = Completer<void>();
      final aRelease = Completer<List<ServiceOrderEntity>>();
      final publishedOrderCounts = <int>[];

      final container = ProviderContainer(
        overrides: [
          authenticatedSessionKeyProvider.overrideWith(
            (ref) => ref.watch(_controlledSessionKeyProvider),
          ),
          serviceOrdersProvider.overrideWith(
            () => _ControlledOrdersNotifier(aEntered, aRelease),
          ),
          customersProvider.overrideWith(_EmptyCustomersNotifier.new),
          equipmentsProvider.overrideWith(_EmptyEquipmentsNotifier.new),
          financeSummaryProvider.overrideWith(
            (ref) async => const FinanceSummary(
              totalRevenue: MoneyMinor.zero,
              monthRevenue: MoneyMinor.zero,
              pendingAmount: MoneyMinor.zero,
              totalPayments: 0,
              pendingPayments: 0,
              revenueByMethod: {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final subscription = container.listen<AsyncValue<DashboardMetrics>>(
        dashboardMetricsProvider,
        (previous, next) {
          next.whenData(
            (metrics) => publishedOrderCounts.add(metrics.totalOrders),
          );
        },
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final aFuture = container
          .read(dashboardMetricsProvider.future)
          .then<Object>((value) => value, onError: (Object error) => error);
      await aEntered.future;

      container.read(_controlledSessionKeyProvider.notifier).state = _keyB;
      final bMetrics = await container.read(dashboardMetricsProvider.future);
      expect(bMetrics.totalOrders, 2);

      aRelease.complete(<ServiceOrderEntity>[_order('a-only')]);
      await aFuture;
      await Future<void>.value();

      expect(publishedOrderCounts, contains(2));
      expect(publishedOrderCounts, isNot(contains(1)));
    },
  );
}

final class _ControlledOrdersNotifier extends ServiceOrdersNotifier {
  _ControlledOrdersNotifier(this.aEntered, this.aRelease);

  final Completer<void> aEntered;
  final Completer<List<ServiceOrderEntity>> aRelease;

  @override
  Future<List<ServiceOrderEntity>> build() {
    final key = ref.watch(authenticatedSessionKeyProvider);
    if (key == _keyA) {
      if (!aEntered.isCompleted) aEntered.complete();
      return aRelease.future;
    }
    return Future<List<ServiceOrderEntity>>.value(
      <ServiceOrderEntity>[_order('b-1'), _order('b-2')],
    );
  }
}

final class _EmptyCustomersNotifier extends CustomersNotifier {
  @override
  Future<List<CustomerEntity>> build() async => const <CustomerEntity>[];
}

final class _EmptyEquipmentsNotifier extends EquipmentsNotifier {
  @override
  Future<List<EquipmentEntity>> build() async => const <EquipmentEntity>[];
}

ServiceOrderEntity _order(String id) => ServiceOrderEntity(
      id: id,
      customerId: 'customer',
      equipmentId: 'equipment',
      status: ServiceOrderStatusEnum.diagnostico,
      problemDescription: id,
      updatedAt: '2026-09-10T12:00:00Z',
    );
