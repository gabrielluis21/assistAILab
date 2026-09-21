import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/commands/command_intent.dart';
import '../../../core/database/auth_scoped_database_manager.dart';
import '../../auth/application/auth_provider.dart';
import '../../auth/application/session_api_client.dart';
import '../../auth/domain/entities/auth_scope.dart';
import '../../auth/domain/entities/session_state.dart';
import '../data/customer_quote_command_gateway.dart';
import '../domain/customer_quote.dart';
import 'customer_quote_decision_executor.dart';
import 'customer_service_orders_provider.dart';

export '../domain/customer_quote.dart'
    show
        CustomerQuoteDecision,
        CustomerQuoteDecisionException,
        CustomerQuoteProjectionUncertaintyException;

typedef _CustomerQuoteSessionBinding = ({
  AuthenticatedSessionKey sessionKey,
  BoundDatabaseHandle databaseHandle,
});

final customerQuoteCommandGatewayProvider =
    Provider<CustomerQuoteCommandGateway>(
  (ref) => CustomerQuoteHttpCommandGateway(
    ref.watch(sessionApiClientProvider),
  ),
);

final customerQuoteCommandIntentRepositoryProvider =
    Provider<CommandIntentRepository>(
  (ref) => CommandIntentLocalDataSource(),
);

final customerQuoteOperationIdFactoryProvider = Provider<String Function()>(
  (ref) => const Uuid().v4,
);

class CustomerQuoteDecisionNotifier extends AsyncNotifier<void> {
  @override
  Future<void> build() async {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    final binding = _captureBinding(sessionKey);
    _ensureBindingCurrent(binding);
    await ref
        .read(customerQuoteCommandIntentRepositoryProvider)
        .recoverInterruptedSending(
          ownedCommandTypes: customerQuoteOwnedCommandTypes,
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
  }

  Future<bool> submit({
    required String serviceOrderId,
    required CustomerQuoteDecision decision,
    String? reason,
  }) async {
    if (state.isLoading) return false;
    if (!ref.read(isOnlineSessionProvider)) {
      throw const CustomerQuoteDecisionException(
        503,
        'CUSTOMER_QUOTE_REQUIRES_ONLINE_SESSION',
        safeMessage: 'Conecte-se à internet para responder ao orçamento.',
      );
    }
    final binding = _captureBinding(
      ref.read(authenticatedSessionKeyProvider),
    );
    _ensureBindingCurrent(binding);
    state = const AsyncLoading();

    try {
      final gateway = ref.read(customerQuoteCommandGatewayProvider);
      _ensureBindingCurrent(binding);
      final identity = await _resolveDecisionIdentity(
        binding: binding,
        gateway: gateway,
        serviceOrderId: serviceOrderId,
        decision: decision,
        reason: reason,
      );
      await CustomerQuoteDecisionExecutor(
        gateway: gateway,
        intentRepository:
            ref.read(customerQuoteCommandIntentRepositoryProvider),
        database: binding.databaseHandle.database,
        isBindingCurrent: () => _isBindingCurrent(binding),
        operationIdFactory: ref.read(customerQuoteOperationIdFactoryProvider),
      ).decide(
        identity: identity,
      );
      _ensureBindingCurrent(binding);
      await ref.read(customerServiceOrdersProvider.notifier).refreshSilently();
      _ensureBindingCurrent(binding);
      state = const AsyncData(null);
      return true;
    } catch (error, stackTrace) {
      if (_isBindingCurrent(binding)) {
        state = AsyncError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<CustomerQuoteDecisionIdentity> _resolveDecisionIdentity({
    required _CustomerQuoteSessionBinding binding,
    required CustomerQuoteCommandGateway gateway,
    required String serviceOrderId,
    required CustomerQuoteDecision decision,
    required String? reason,
  }) async {
    _ensureBindingCurrent(binding);
    final unresolved = await ref
        .read(customerQuoteCommandIntentRepositoryProvider)
        .findUnresolved(
          commandType: customerQuoteDecisionCommandType,
          targetId: serviceOrderId,
          executor: binding.databaseHandle.database,
        );
    _ensureBindingCurrent(binding);
    final matching =
        <({CommandIntent intent, CustomerQuoteDecisionIdentity identity})>[];
    for (final intent in unresolved) {
      final identity = CustomerQuoteDecisionIdentity.fromIntent(intent);
      if (identity.matchesRequestedAction(
        requestedDecision: decision,
        requestedReason: reason,
      )) {
        matching.add((intent: intent, identity: identity));
      }
    }
    if (matching.length > 1) {
      throw StateError('Ambiguous unresolved CUSTOMER quote decision.');
    }
    if (matching.length == 1) {
      final replay = matching.single;
      if (replay.intent.lifecycle == CommandIntentLifecycle.sending) {
        throw StateError('A matching CUSTOMER quote decision is in flight.');
      }
      return replay.identity;
    }

    _ensureBindingCurrent(binding);
    final quote = await gateway.readActionableQuote(serviceOrderId);
    _ensureBindingCurrent(binding);
    return CustomerQuoteDecisionIdentity.fromQuote(
      quote: quote,
      decision: decision,
      reason: reason,
    );
  }

  _CustomerQuoteSessionBinding _captureBinding(
    AuthenticatedSessionKey? sessionKey,
  ) {
    if (sessionKey == null || sessionKey.scope is! CustomerAuthScope) {
      throw const CustomerQuoteDecisionException(
        403,
        'CUSTOMER_CONTEXT_REQUIRED',
        safeMessage: 'Apenas clientes podem responder ao orçamento.',
      );
    }
    final manager = ref.read(customerPortalDatabaseManagerProvider);
    final handle = manager.currentHandle;
    if (handle == null ||
        handle.authScope != sessionKey.scope ||
        handle.sessionGeneration != sessionKey.sessionGeneration ||
        !manager.isCurrentHandle(handle)) {
      throw StateError(
        'No current database is bound to the authenticated CUSTOMER session.',
      );
    }
    return (sessionKey: sessionKey, databaseHandle: handle);
  }

  bool _isBindingCurrent(_CustomerQuoteSessionBinding binding) {
    final manager = ref.read(customerPortalDatabaseManagerProvider);
    return ref.read(authenticatedSessionKeyProvider) == binding.sessionKey &&
        binding.databaseHandle.authScope == binding.sessionKey.scope &&
        binding.databaseHandle.sessionGeneration ==
            binding.sessionKey.sessionGeneration &&
        manager.isCurrentHandle(binding.databaseHandle);
  }

  void _ensureBindingCurrent(_CustomerQuoteSessionBinding binding) {
    if (!_isBindingCurrent(binding)) {
      throw StateError('Customer quote operation belongs to a stale session.');
    }
  }
}

final customerQuoteDecisionProvider =
    AsyncNotifierProvider<CustomerQuoteDecisionNotifier, void>(
  CustomerQuoteDecisionNotifier.new,
);
