import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../service_orders/service_orders_provider.dart';
import '../service_orders/service_order_entity.dart';
import '../customers/customers_provider.dart';
import '../equipment/equipments_provider.dart';
import '../finance/payments_provider.dart';

class DashboardMetrics {
  final int totalOrders;
  final int ordersOpen;
  final int ordersInExecution;
  final int ordersReady;
  final int ordersDelivered;
  final int totalCustomers;
  final int totalEquipments;
  final double monthRevenue;
  final double totalRevenue;
  final double pendingRevenue;
  final int paymentsToConfirm;

  const DashboardMetrics({
    required this.totalOrders,
    required this.ordersOpen,
    required this.ordersInExecution,
    required this.ordersReady,
    required this.ordersDelivered,
    required this.totalCustomers,
    required this.totalEquipments,
    required this.monthRevenue,
    required this.totalRevenue,
    required this.pendingRevenue,
    required this.paymentsToConfirm,
  });
}

final dashboardMetricsProvider = FutureProvider<DashboardMetrics>((ref) async {
  // Watch all providers simultaneously
  final orders = await ref.watch(serviceOrdersProvider.future);
  final customers = await ref.watch(customersProvider.future);
  final equipments = await ref.watch(equipmentsProvider.future);
  final financeSummary = await ref.watch(financeSummaryProvider.future);

  final ordersOpen = orders
      .where((o) =>
          o.status == ServiceOrderStatusEnum.draft ||
          o.status == ServiceOrderStatusEnum.diagnostico ||
          o.status == ServiceOrderStatusEnum.aguardandoAprovacao)
      .length;

  final ordersInExecution = orders
      .where((o) => o.status == ServiceOrderStatusEnum.emExecucao)
      .length;

  final ordersReady =
      orders.where((o) => o.status == ServiceOrderStatusEnum.pronto).length;

  final ordersDelivered =
      orders.where((o) => o.status == ServiceOrderStatusEnum.entregue).length;

  return DashboardMetrics(
    totalOrders: orders.length,
    ordersOpen: ordersOpen,
    ordersInExecution: ordersInExecution,
    ordersReady: ordersReady,
    ordersDelivered: ordersDelivered,
    totalCustomers: customers.length,
    totalEquipments: equipments.length,
    monthRevenue: financeSummary.monthRevenue,
    totalRevenue: financeSummary.totalRevenue,
    pendingRevenue: financeSummary.pendingAmount,
    paymentsToConfirm: financeSummary.pendingPayments,
  );
});
