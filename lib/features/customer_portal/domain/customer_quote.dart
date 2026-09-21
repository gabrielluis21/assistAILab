import 'dart:convert';

import '../../../core/commands/command_failure.dart';
import '../../../core/commands/command_intent.dart';
import '../../../core/money/money_minor.dart';

enum CustomerQuoteDecision {
  approve('APPROVE'),
  reject('REJECT');

  const CustomerQuoteDecision(this.wireValue);

  final String wireValue;
}

enum CustomerQuoteDecisionMode {
  initialApproval,
  reapproval;

  static CustomerQuoteDecisionMode fromWire(Object? value) => switch (value) {
        'INITIAL_APPROVAL' => CustomerQuoteDecisionMode.initialApproval,
        'REAPPROVAL' => CustomerQuoteDecisionMode.reapproval,
        _ =>
          throw const FormatException('Invalid customer quote decisionMode.'),
      };
}

final class CustomerQuoteItem {
  const CustomerQuoteItem({
    required this.description,
    required this.quantity,
    required this.unitPrice,
    required this.totalPrice,
  });

  final String description;
  final int quantity;
  final MoneyMinor unitPrice;
  final MoneyMinor totalPrice;
}

final class CustomerQuote {
  const CustomerQuote({
    required this.serviceOrderId,
    required this.quoteRevisionId,
    required this.revisionNumber,
    required this.decisionMode,
    required this.diagnosis,
    required this.items,
    required this.totalAmount,
    required this.changeReason,
    required this.createdAt,
  });

  final String serviceOrderId;
  final String quoteRevisionId;
  final int revisionNumber;
  final CustomerQuoteDecisionMode decisionMode;
  final String? diagnosis;
  final List<CustomerQuoteItem> items;
  final MoneyMinor totalAmount;
  final String? changeReason;
  final DateTime createdAt;

  factory CustomerQuote.fromWire(
    Map<String, dynamic> wire, {
    required String expectedServiceOrderId,
  }) {
    final serviceOrderId = _requiredString(wire, 'serviceOrderId');
    if (serviceOrderId != expectedServiceOrderId) {
      throw const FormatException('Customer quote serviceOrderId mismatch.');
    }
    final quote = _requiredMap(wire['quote']);
    final quoteRevisionId = _requiredString(quote, 'quoteRevisionId');
    if (!_uuidPattern.hasMatch(quoteRevisionId)) {
      throw const FormatException('Invalid customer quoteRevisionId.');
    }
    final revisionNumber = quote['revisionNumber'];
    if (revisionNumber is! int || revisionNumber < 1) {
      throw const FormatException('Invalid customer quote revisionNumber.');
    }
    final rawItems = quote['items'];
    if (rawItems is! List) {
      throw const FormatException('Invalid customer quote items.');
    }
    final items = <CustomerQuoteItem>[];
    final totals = <MoneyMinor>[];
    for (final rawItem in rawItems) {
      final item = _requiredMap(rawItem);
      final quantity = item['quantity'];
      if (quantity is! int || quantity < 1 || quantity > 2147483647) {
        throw const FormatException('Invalid customer quote quantity.');
      }
      final unitPrice = MoneyMinor.serviceOrderFromJson(item['unitPriceMinor']);
      final totalPrice =
          MoneyMinor.serviceOrderFromJson(item['totalPriceMinor']);
      if (unitPrice.multiplyByQuantity(
            quantity,
            maximum: MoneyMinor.serviceOrderMaximum,
          ) !=
          totalPrice) {
        throw const FormatException('Invalid customer quote line total.');
      }
      totals.add(totalPrice);
      items.add(CustomerQuoteItem(
        description: _requiredString(item, 'description'),
        quantity: quantity,
        unitPrice: unitPrice,
        totalPrice: totalPrice,
      ));
    }
    final totalAmount =
        MoneyMinor.serviceOrderFromJson(quote['totalAmountMinor']);
    if (MoneyMinor.sum(
          totals,
          maximum: MoneyMinor.serviceOrderMaximum,
        ) !=
        totalAmount) {
      throw const FormatException('Invalid customer quote aggregate total.');
    }
    final createdAtText = _requiredString(quote, 'createdAt');
    final createdAt = DateTime.tryParse(createdAtText);
    if (createdAt == null) {
      throw const FormatException('Invalid customer quote createdAt.');
    }
    return CustomerQuote(
      serviceOrderId: serviceOrderId,
      quoteRevisionId: quoteRevisionId,
      revisionNumber: revisionNumber,
      decisionMode: CustomerQuoteDecisionMode.fromWire(quote['decisionMode']),
      diagnosis: _nullableString(quote, 'diagnosis'),
      items: List.unmodifiable(items),
      totalAmount: totalAmount,
      changeReason: _nullableString(quote, 'changeReason'),
      createdAt: createdAt,
    );
  }
}

final class CustomerQuoteDecisionIdentity {
  const CustomerQuoteDecisionIdentity({
    required this.serviceOrderId,
    required this.quoteRevisionId,
    required this.decision,
    required this.reason,
  });

  final String serviceOrderId;
  final String quoteRevisionId;
  final CustomerQuoteDecision decision;
  final String? reason;

  factory CustomerQuoteDecisionIdentity.fromQuote({
    required CustomerQuote quote,
    required CustomerQuoteDecision decision,
    String? reason,
  }) =>
      CustomerQuoteDecisionIdentity(
        serviceOrderId: quote.serviceOrderId,
        quoteRevisionId: quote.quoteRevisionId,
        decision: decision,
        reason: normalizeCustomerQuoteDecisionReason(reason),
      );

  factory CustomerQuoteDecisionIdentity.fromIntent(CommandIntent intent) {
    if (intent.commandType != 'CUSTOMER_QUOTE_DECISION') {
      throw const FormatException('Unexpected CUSTOMER command type.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(intent.canonicalPayload);
    } catch (_) {
      throw const FormatException('Malformed CUSTOMER command payload.');
    }
    final payload = _requiredMap(decoded);
    final expectedKeys = <String>{
      'decision',
      'quoteRevisionId',
      if (payload.containsKey('reason')) 'reason',
      'serviceOrderId',
    };
    if (payload.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(payload.keys.toSet()).isNotEmpty) {
      throw const FormatException('Unexpected CUSTOMER command payload.');
    }
    final serviceOrderId = _requiredString(payload, 'serviceOrderId');
    if (serviceOrderId != intent.targetId) {
      throw const FormatException('CUSTOMER command target mismatch.');
    }
    final quoteRevisionId = _requiredString(payload, 'quoteRevisionId');
    if (!_uuidPattern.hasMatch(quoteRevisionId)) {
      throw const FormatException('Invalid CUSTOMER command quoteRevisionId.');
    }
    final decision = switch (payload['decision']) {
      'APPROVE' => CustomerQuoteDecision.approve,
      'REJECT' => CustomerQuoteDecision.reject,
      _ => throw const FormatException('Invalid CUSTOMER command decision.'),
    };
    final rawReason = payload['reason'];
    if (rawReason != null && rawReason is! String) {
      throw const FormatException('Invalid CUSTOMER command reason.');
    }
    final reason = normalizeCustomerQuoteDecisionReason(rawReason as String?);
    if (rawReason != reason) {
      throw const FormatException('Non-canonical CUSTOMER command reason.');
    }
    return CustomerQuoteDecisionIdentity(
      serviceOrderId: serviceOrderId,
      quoteRevisionId: quoteRevisionId,
      decision: decision,
      reason: reason,
    );
  }

  bool matchesRequestedAction({
    required CustomerQuoteDecision requestedDecision,
    required String? requestedReason,
  }) =>
      decision == requestedDecision &&
      reason == normalizeCustomerQuoteDecisionReason(requestedReason);

  Map<String, Object?> toCanonicalPayload() => {
        'decision': decision.wireValue,
        'quoteRevisionId': quoteRevisionId,
        if (reason != null) 'reason': reason,
        'serviceOrderId': serviceOrderId,
      };
}

final class CustomerQuoteDecisionException extends CommandException {
  const CustomerQuoteDecisionException(
    super.statusCode,
    super.errorCode, {
    this.safeMessage,
  });

  final String? safeMessage;

  @override
  String get message {
    final explicit = safeMessage;
    if (explicit != null) return explicit;
    if (classifyCommandFailure(this) == CommandFailureDisposition.unknown) {
      return 'Não foi possível confirmar o resultado da operação. '
          'Tente novamente.';
    }
    return 'Não foi possível registrar sua resposta ao orçamento.';
  }
}

final class CustomerQuoteProjectionUncertaintyException implements Exception {
  const CustomerQuoteProjectionUncertaintyException({
    required this.cause,
    this.safeMessage,
  });

  final Object cause;
  final String? safeMessage;

  String get message {
    final explicit = safeMessage;
    if (explicit != null) return explicit;
    if (cause is CustomerQuoteDecisionException) {
      final decisionException = cause as CustomerQuoteDecisionException;
      final explicitCauseMessage = decisionException.safeMessage;
      if (explicitCauseMessage != null) return explicitCauseMessage;
    }
    return 'Não foi possível confirmar o resultado da operação. '
        'Tente novamente.';
  }

  int? get statusCode =>
      cause is CommandException ? (cause as CommandException).statusCode : null;

  String? get errorCode =>
      cause is CommandException ? (cause as CommandException).errorCode : null;

  @override
  String toString() =>
      'CustomerQuoteProjectionUncertaintyException(cause: $cause)';
}

String? normalizeCustomerQuoteDecisionReason(String? reason) {
  final normalized = reason?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.length > 1000) {
    throw ArgumentError.value(reason, 'reason', 'Must not exceed 1000 chars.');
  }
  return normalized;
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
);

Map<String, dynamic> _requiredMap(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Customer quote value must be an object.');
  }
  return value;
}

String _requiredString(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Customer quote $key is missing.');
  }
  return value;
}

String? _nullableString(Map<String, dynamic> wire, String key) {
  final value = wire[key];
  if (value != null && value is! String) {
    throw FormatException('Customer quote $key is malformed.');
  }
  return value as String?;
}
