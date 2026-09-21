import 'package:sqflite/sqflite.dart';

import '../../../core/commands/command_executor.dart';
import '../../../core/commands/command_intent.dart';
import '../../../core/sync/sync_projection_applier.dart';
import '../data/customer_quote_command_gateway.dart';
import '../domain/customer_quote.dart';

const customerQuoteDecisionCommandType = 'CUSTOMER_QUOTE_DECISION';
const customerQuoteOwnedCommandTypes = <String>{
  customerQuoteDecisionCommandType,
};

final class CustomerQuoteDecisionExecutor {
  const CustomerQuoteDecisionExecutor({
    required this.gateway,
    required this.intentRepository,
    required this.database,
    required this.isBindingCurrent,
    required this.operationIdFactory,
  });

  final CustomerQuoteCommandGateway gateway;
  final CommandIntentRepository intentRepository;
  final Database database;
  final bool Function() isBindingCurrent;
  final String Function() operationIdFactory;

  Future<CustomerServiceOrderProjection> decide({
    required CustomerQuoteDecisionIdentity identity,
  }) {
    return CommandExecutor(
      intentRepository: intentRepository,
      database: database,
      isBindingCurrent: isBindingCurrent,
      operationIdFactory: operationIdFactory,
    ).execute(
      commandType: customerQuoteDecisionCommandType,
      targetId: identity.serviceOrderId,
      payload: identity.toCanonicalPayload(),
      dispatch: (operationId) async {
        await gateway.submitDecision(
          operationId: operationId,
          serviceOrderId: identity.serviceOrderId,
          quoteRevisionId: identity.quoteRevisionId,
          decision: identity.decision,
          reason: identity.reason,
        );
        _ensureBindingCurrent();
        final CustomerServiceOrderProjection projection;
        try {
          projection = await gateway.readProjection(
            identity.serviceOrderId,
          );
          if (projection.serviceOrderId != identity.serviceOrderId ||
              projection.wire['id'] != identity.serviceOrderId ||
              projection.wire['contractVersion'] != 2) {
            throw const CustomerQuoteDecisionException(
              502,
              'CUSTOMER_PROJECTION_RESPONSE_INVALID',
            );
          }
          _ensureBindingCurrent();
        } on Object catch (error) {
          _ensureBindingCurrent();
          if (error is StateError) {
            rethrow;
          }
          throw CustomerQuoteProjectionUncertaintyException(
            cause: error,
          );
        }
        return projection;
      },
      authoritativeCommit: (executor, projection) =>
          SyncProjectionApplier.applyRecord(executor, {
        'entityType': 'SERVICE_ORDER',
        'entityId': projection.serviceOrderId,
        'data': projection.wire,
      }),
    );
  }

  void _ensureBindingCurrent() {
    if (!isBindingCurrent()) {
      throw StateError('Customer quote decision belongs to a stale session.');
    }
  }
}
