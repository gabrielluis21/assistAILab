import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/application/auth_provider.dart';
import '../../features/customer_portal/application/customer_quote_decision_provider.dart';
import '../../features/customer_portal/application/customer_service_orders_provider.dart';
import '../../features/customers/customers_provider.dart';
import '../../features/dashboard/dashboard_provider.dart';
import '../../features/equipment/equipments_provider.dart';
import '../../features/finance/payments_provider.dart';
import '../../features/onboarding/application/onboarding_provider.dart';
import '../../features/parts/parts_provider.dart';
import '../../features/service_orders/printing/service_order_print_data_provider.dart';
import '../../features/service_orders/service_order_details_provider.dart';
import '../../features/service_orders/service_orders_provider.dart';

/// Application-level cache boundary keyed by AuthScope + session generation.
///
/// Feature providers also bind their own async work to the key. This central
/// invalidation ensures already-materialized provider families and aggregate
/// caches are detached before a new session can render. Finance internals are
/// intentionally untouched; their existing providers are only invalidated at
/// this external lifecycle boundary.
final sessionCacheIsolationProvider = Provider<void>((ref) {
  ref.listen(
    authenticatedSessionKeyProvider,
    (previous, next) {
      if (previous == next) return;

      ref.invalidate(customerServiceOrdersProvider);
      ref.invalidate(customerQuoteDecisionProvider);
      ref.invalidate(serviceOrderItemsProvider);
      ref.invalidate(serviceOrderPrintDataProvider);
      ref.invalidate(serviceOrdersProvider);
      ref.invalidate(customersProvider);
      ref.invalidate(equipmentsProvider);
      ref.invalidate(partsProvider);
      ref.invalidate(dashboardMetricsProvider);
      ref.invalidate(onboardingProvider);

      // External invalidation only: Finance business logic remains unchanged.
      ref.invalidate(financeSummaryProvider);
      ref.invalidate(paymentsProvider);
    },
  );
});
