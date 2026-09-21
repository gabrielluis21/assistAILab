import 'dart:convert';

import 'package:assistailab/features/customer_portal/data/customer_quote_command_gateway.dart';
import 'package:assistailab/features/customer_portal/domain/customer_quote.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const _orderId = '10000000-0000-4000-8000-000000000001';
const _revisionId = '20000000-0000-4000-8000-000000000002';

void main() {
  test('customer-quote parses the exact authoritative quoteRevisionId',
      () async {
    final gateway = _gateway(getBody: _quoteWire());
    final quote = await gateway.readActionableQuote(_orderId);
    expect(quote.quoteRevisionId, _revisionId);
    expect(quote.serviceOrderId, _orderId);
    expect(quote.decisionMode, CustomerQuoteDecisionMode.initialApproval);
  });

  for (final entry in <String, Map<String, dynamic>>{
    'missing quoteRevisionId': _quoteWire()
      ..['quote'].remove('quoteRevisionId'),
    'empty quoteRevisionId': _quoteWire()..['quote']['quoteRevisionId'] = '',
    'malformed response': {'serviceOrderId': _orderId, 'quote': 'invalid'},
  }.entries) {
    test('${entry.key} fails closed', () async {
      await expectLater(
        _gateway(getBody: entry.value).readActionableQuote(_orderId),
        throwsA(isA<CustomerQuoteDecisionException>()),
      );
    });
  }

  test('unauthorized quote read is never treated as an actionable quote',
      () async {
    final gateway = CustomerQuoteHttpCommandGateway.forTesting(
      get: (_) async => http.Response('{"error":"FORBIDDEN"}', 403),
      post: _unusedPost,
    );
    await expectLater(
      gateway.readActionableQuote(_orderId),
      throwsA(
        isA<CustomerQuoteDecisionException>()
            .having((error) => error.statusCode, 'statusCode', 403),
      ),
    );
  });

  test('decision sends exact route, body and X-Operation-Id', () async {
    String? endpoint;
    Map<String, dynamic>? capturedBody;
    Map<String, String>? capturedHeaders;
    final gateway = CustomerQuoteHttpCommandGateway.forTesting(
      get: (_) async => http.Response('{}', 500),
      post: (path, {body, headers = const {}}) async {
        endpoint = path;
        capturedBody = body;
        capturedHeaders = headers;
        return http.Response(
          jsonEncode(_decisionResponse(decision: 'REJECT')),
          200,
        );
      },
    );
    await gateway.submitDecision(
      operationId: 'operation-1',
      serviceOrderId: _orderId,
      quoteRevisionId: _revisionId,
      decision: CustomerQuoteDecision.reject,
      reason: '  valor alto  ',
    );
    expect(endpoint, '/service-orders/$_orderId/quote-decision');
    expect(capturedHeaders, {'X-Operation-Id': 'operation-1'});
    expect(capturedBody, {
      'quoteRevisionId': _revisionId,
      'decision': 'REJECT',
      'reason': 'valor alto',
    });
  });

  test('projection uses canonical refresh route and validates identity',
      () async {
    String? endpoint;
    final projection = _projectionWire(status: 'EM_EXECUCAO');
    final gateway = CustomerQuoteHttpCommandGateway.forTesting(
      get: (path) async {
        endpoint = path;
        return http.Response(jsonEncode(projection), 200);
      },
      post: _unusedPost,
    );
    final result = await gateway.readProjection(_orderId);
    expect(endpoint, '/service-orders/$_orderId/projection');
    expect(result.wire, projection);
  });
}

CustomerQuoteHttpCommandGateway _gateway({
  required Map<String, dynamic> getBody,
}) =>
    CustomerQuoteHttpCommandGateway.forTesting(
      get: (_) async => http.Response(jsonEncode(getBody), 200),
      post: _unusedPost,
    );

Future<http.Response> _unusedPost(
  String _, {
  Map<String, dynamic>? body,
  Map<String, String> headers = const {},
}) async =>
    http.Response('{}', 500);

Map<String, dynamic> _quoteWire() => {
      'serviceOrderId': _orderId,
      'quote': {
        'quoteRevisionId': _revisionId,
        'revisionNumber': 1,
        'decisionMode': 'INITIAL_APPROVAL',
        'diagnosis': 'Diagnóstico',
        'items': [
          {
            'description': 'Serviço',
            'quantity': 2,
            'unitPriceMinor': 500,
            'totalPriceMinor': 1000,
          }
        ],
        'totalAmountMinor': 1000,
        'changeReason': 'Orçamento inicial',
        'createdAt': '2026-09-21T10:00:00.000Z',
      },
    };

Map<String, dynamic> _decisionResponse({required String decision}) => {
      'serviceOrderId': _orderId,
      'status': decision == 'APPROVE' ? 'EM_EXECUCAO' : 'CANCELADO',
      'quoteDecision': {
        'quoteRevisionId': _revisionId,
        'decision': decision,
        'reason': decision == 'REJECT' ? 'valor alto' : null,
        'decidedAt': '2026-09-21T10:01:00.000Z',
      },
    };

Map<String, dynamic> _projectionWire({required String status}) => {
      'contractVersion': 2,
      'projectionRevision': '2',
      'id': _orderId,
      'friendlyId': 10,
      'equipmentId': 'equipment-1',
      'status': status,
      'problemDescription': 'Não liga',
      'solution': null,
      'createdAt': '2026-09-20T10:00:00.000Z',
      'updatedAt': '2026-09-21T10:01:00.000Z',
      'diagnosis': 'Diagnóstico',
      'totalAmountMinor': 1000,
      'items': [
        {
          'description': 'Serviço',
          'quantity': 2,
          'unitPriceMinor': 500,
          'totalPriceMinor': 1000,
        }
      ],
    };
