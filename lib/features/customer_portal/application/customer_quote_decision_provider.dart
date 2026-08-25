import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sync/sync_providers.dart';
import '../../../core/sync/sync_trigger.dart';
import '../../auth/application/auth_provider.dart';
import 'customer_service_orders_provider.dart';

enum CustomerQuoteDecision {
  approve,
  reject,
}

class CustomerQuoteDecisionException implements Exception {
  const CustomerQuoteDecisionException(
    this.message,
  );

  final String message;

  @override
  String toString() => message;
}

class CustomerQuoteDecisionNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {}

  Future<bool> submit({
    required String serviceOrderId,
    required CustomerQuoteDecision decision,
    String? reason,
  }) async {
    if (state.isLoading) {
      return false;
    }

    final auth = ref.read(
      authStateProvider,
    );

    final user = auth.valueOrNull;

    if (user == null || user.role.trim().toUpperCase() != 'CUSTOMER') {
      throw const CustomerQuoteDecisionException(
        'Apenas clientes podem responder ao orçamento.',
      );
    }

    state = const AsyncLoading();

    try {
      final apiClient = ref.read(
        apiClientProvider,
      );

      final normalizedReason = reason?.trim();

      final response = await apiClient.post(
        '/api/v1/service-orders/'
        '$serviceOrderId/quote-decision',
        body: {
          'decision':
              decision == CustomerQuoteDecision.approve ? 'APPROVE' : 'REJECT',
          if (normalizedReason != null && normalizedReason.isNotEmpty)
            'reason': normalizedReason,
        },
      );

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw CustomerQuoteDecisionException(
          _extractErrorMessage(
            response.body,
          ),
        );
      }

      state = const AsyncData(null);

      // A alteração aconteceu no servidor.
      // Solicitamos novo ciclo para trazer imediatamente
      // o estado oficial para o SQLite local.
      ref.read(syncSchedulerProvider).requestSync(
            SyncTrigger.localMutation,
          );

      // Também permitimos atualização imediata caso
      // o backend já tenha refletido a mudança no pull.
      await ref
          .read(
            customerServiceOrdersProvider.notifier,
          )
          .refreshSilently();

      return true;
    } catch (error, stackTrace) {
      state = AsyncError(
        error,
        stackTrace,
      );

      rethrow;
    }
  }
}

final customerQuoteDecisionProvider =
    AsyncNotifierProvider<CustomerQuoteDecisionNotifier, void>(
  CustomerQuoteDecisionNotifier.new,
);

String _extractErrorMessage(
  String responseBody,
) {
  try {
    final decoded = jsonDecode(responseBody);

    if (decoded is Map<String, dynamic>) {
      final error = decoded['error'];

      if (error is String && error.trim().isNotEmpty) {
        return error;
      }
    }
  } catch (_) {
    // Resposta não JSON.
  }

  return 'Não foi possível registrar sua resposta ao orçamento.';
}
