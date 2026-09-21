import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../auth/application/session_api_client.dart';
import '../../service_orders/service_order_entity.dart';
import '../domain/customer_quote.dart';

typedef CustomerQuoteGet = Future<http.Response> Function(String endpoint);
typedef CustomerQuotePost = Future<http.Response> Function(
  String endpoint, {
  Map<String, dynamic>? body,
  Map<String, String> headers,
});

final class CustomerServiceOrderProjection {
  const CustomerServiceOrderProjection({
    required this.serviceOrderId,
    required this.wire,
  });

  final String serviceOrderId;
  final Map<String, dynamic> wire;
}

abstract interface class CustomerQuoteCommandGateway {
  Future<CustomerQuote> readActionableQuote(String serviceOrderId);

  Future<void> submitDecision({
    required String operationId,
    required String serviceOrderId,
    required String quoteRevisionId,
    required CustomerQuoteDecision decision,
    String? reason,
  });

  Future<CustomerServiceOrderProjection> readProjection(String serviceOrderId);
}

final class CustomerQuoteHttpCommandGateway
    implements CustomerQuoteCommandGateway {
  CustomerQuoteHttpCommandGateway(SessionApiClient client)
      : this.forTesting(get: client.get, post: client.postWithHeaders);

  const CustomerQuoteHttpCommandGateway.forTesting({
    required CustomerQuoteGet get,
    required CustomerQuotePost post,
  })  : _get = get,
        _post = post;

  final CustomerQuoteGet _get;
  final CustomerQuotePost _post;

  @override
  Future<CustomerQuote> readActionableQuote(String serviceOrderId) async {
    final response = await _get(
      '/service-orders/$serviceOrderId/customer-quote',
    ).timeout(const Duration(seconds: 15));
    final body = _decodeResponse(response);
    try {
      return CustomerQuote.fromWire(
        body,
        expectedServiceOrderId: serviceOrderId,
      );
    } on FormatException {
      throw const CustomerQuoteDecisionException(
        502,
        'CUSTOMER_QUOTE_RESPONSE_INVALID',
      );
    }
  }

  @override
  Future<void> submitDecision({
    required String operationId,
    required String serviceOrderId,
    required String quoteRevisionId,
    required CustomerQuoteDecision decision,
    String? reason,
  }) async {
    final normalizedReason = normalizeCustomerQuoteDecisionReason(reason);
    final response = await _post(
      '/service-orders/$serviceOrderId/quote-decision',
      headers: {'X-Operation-Id': operationId},
      body: {
        'quoteRevisionId': quoteRevisionId,
        'decision': decision.wireValue,
        if (normalizedReason != null) 'reason': normalizedReason,
      },
    ).timeout(const Duration(seconds: 15));
    final body = _decodeResponse(response);
    try {
      _validateDecisionResponse(
        body,
        serviceOrderId: serviceOrderId,
        quoteRevisionId: quoteRevisionId,
        decision: decision,
      );
    } on FormatException {
      throw const CustomerQuoteDecisionException(
        502,
        'CUSTOMER_QUOTE_RESPONSE_INVALID',
      );
    }
  }

  @override
  Future<CustomerServiceOrderProjection> readProjection(
    String serviceOrderId,
  ) async {
    final response = await _get(
      '/service-orders/$serviceOrderId/projection',
    ).timeout(const Duration(seconds: 15));
    final body = _decodeResponse(response);
    if (body['id'] != serviceOrderId || body['contractVersion'] != 2) {
      throw const CustomerQuoteDecisionException(
        502,
        'CUSTOMER_PROJECTION_RESPONSE_INVALID',
      );
    }
    return CustomerServiceOrderProjection(
      serviceOrderId: serviceOrderId,
      wire: Map.unmodifiable(body),
    );
  }

  static Map<String, dynamic> _decodeResponse(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const CustomerQuoteDecisionException(
          502,
          'CUSTOMER_QUOTE_RESPONSE_INVALID',
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded is Map ? decoded['error'] : null;
      throw CustomerQuoteDecisionException(
        response.statusCode,
        code is String ? code : 'CUSTOMER_QUOTE_COMMAND_FAILED',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CustomerQuoteDecisionException(
        502,
        'CUSTOMER_QUOTE_RESPONSE_INVALID',
      );
    }
    return decoded;
  }

  static void _validateDecisionResponse(
    Map<String, dynamic> body, {
    required String serviceOrderId,
    required String quoteRevisionId,
    required CustomerQuoteDecision decision,
  }) {
    if (body['serviceOrderId'] != serviceOrderId) {
      throw const FormatException('Decision serviceOrderId mismatch.');
    }
    ServiceOrderStatusExtension.fromDbString(body['status']);
    final rawDecision = body['quoteDecision'];
    if (rawDecision is! Map<String, dynamic> ||
        rawDecision['quoteRevisionId'] != quoteRevisionId ||
        rawDecision['decision'] != decision.wireValue ||
        rawDecision['reason'] != null && rawDecision['reason'] is! String) {
      throw const FormatException('Decision response mismatch.');
    }
    final decidedAt = rawDecision['decidedAt'];
    if (decidedAt is! String || DateTime.tryParse(decidedAt) == null) {
      throw const FormatException('Decision decidedAt is malformed.');
    }
  }
}
