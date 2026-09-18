import 'dart:convert';
import 'dart:async';

import '../../core/commands/command_failure.dart';
import '../../core/money/money_minor.dart';
import '../auth/application/session_api_client.dart';
import 'payment_entity.dart';

final class PaymentCommandException extends CommandException {
  const PaymentCommandException(super.statusCode, super.errorCode);

  @override
  String toString() => 'PaymentCommandException($statusCode): $errorCode';
}

abstract interface class PaymentCommandGateway {
  Future<List<PaymentEntity>> listAll();

  Future<PaymentEntity> create({
    required String operationId,
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  });

  Future<PaymentEntity> transition({
    required String operationId,
    required String paymentId,
    required PaymentStatus status,
  });
}

/// Publishes a local payment snapshot only after the authoritative command
/// response has completed successfully.
final class PaymentAuthorityCoordinator {
  final PaymentCommandGateway gateway;
  final Future<void> Function(PaymentEntity payment) commit;

  const PaymentAuthorityCoordinator({
    required this.gateway,
    required this.commit,
  });

  Future<PaymentEntity> create({
    required String operationId,
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  }) async {
    final authoritative = await gateway.create(
      operationId: operationId,
      serviceOrderId: serviceOrderId,
      amount: amount,
      method: method,
      notes: notes,
    );
    await commit(authoritative);
    return authoritative;
  }

  Future<PaymentEntity> transition({
    required String operationId,
    required String paymentId,
    required PaymentStatus status,
  }) async {
    final authoritative = await gateway.transition(
      operationId: operationId,
      paymentId: paymentId,
      status: status,
    );
    await commit(authoritative);
    return authoritative;
  }
}

final class PaymentHttpCommandGateway implements PaymentCommandGateway {
  final SessionApiClient _client;

  const PaymentHttpCommandGateway(this._client);

  @override
  Future<List<PaymentEntity>> listAll() async {
    final response = await _client.get('/payments');
    final body = _decodeSuccess(response.statusCode, response.body);
    final values = body['payments'];
    if (values is! List) {
      throw const FormatException('Payment list payload is missing.');
    }
    return values
        .map((value) => _fromWire(_requireMap(value)))
        .toList(growable: false);
  }

  @override
  Future<PaymentEntity> create({
    required String operationId,
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  }) async {
    final response = await _client.postWithHeaders(
      '/payments',
      headers: {'X-Operation-Id': operationId},
      body: {
        'serviceOrderId': serviceOrderId,
        'amountMinor': amount.minorUnits,
        'method': method.toDbString(),
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      },
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['payment']));
  }

  @override
  Future<PaymentEntity> transition({
    required String operationId,
    required String paymentId,
    required PaymentStatus status,
  }) async {
    if (status != PaymentStatus.confirmed &&
        status != PaymentStatus.cancelled) {
      throw ArgumentError.value(status, 'status', 'Unsupported transition');
    }
    final response = await _client.patchWithHeaders(
      '/payments/$paymentId/status',
      headers: {'X-Operation-Id': operationId},
      body: {'status': status.toDbString()},
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['payment']));
  }

  static Map<String, dynamic> _decodeSuccess(int statusCode, String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      if (statusCode >= 200 && statusCode < 300) {
        throw const FormatException('Payment response is not JSON.');
      }
    }
    if (statusCode < 200 || statusCode >= 300) {
      final error = decoded is Map ? decoded['error'] : null;
      throw PaymentCommandException(
        statusCode,
        error is String ? error : 'PAYMENT_COMMAND_FAILED',
      );
    }
    return _requireMap(decoded);
  }

  static Map<String, dynamic> _requireMap(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Payment payload must be an object.');
    }
    return value;
  }

  static PaymentEntity _fromWire(Map<String, dynamic> wire) {
    return PaymentEntity.fromMap({
      'id': wire['id'],
      'service_order_id': wire['serviceOrderId'],
      'customer_id': wire['customerId'],
      'amount_minor': wire['amountMinor'],
      'method': wire['method'],
      'status': wire['status'],
      'notes': wire['notes'],
      'paid_at': wire['paidAt'],
      'created_at': wire['createdAt'],
      'updated_at': wire['updatedAt'],
    });
  }
}
