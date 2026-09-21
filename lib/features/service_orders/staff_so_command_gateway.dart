import 'dart:convert';

import '../../core/commands/command_failure.dart';
import '../auth/application/session_api_client.dart';
import 'service_order_entity.dart';

// ---------------------------------------------------------------------------
// Domain exception
// ---------------------------------------------------------------------------

final class StaffSoCommandException extends CommandException {
  const StaffSoCommandException(super.statusCode, super.errorCode);

  @override
  String toString() => 'StaffSoCommandException($statusCode): $errorCode';
}

// ---------------------------------------------------------------------------
// Abstract gateway — contract only, no policy
// ---------------------------------------------------------------------------

/// Wire contract for all staff-only Service Order commands.
///
/// Each method receives the [operationId] from the caller's durable intent so
/// the backend can enforce idempotency end-to-end.  The backend returns the
/// full updated projection as the authoritative response; callers must commit
/// that projection — never the optimistic local copy.
abstract interface class StaffSoCommandGateway {
  /// `PATCH /service-orders/:id/status` — generic status transition.
  Future<ServiceOrderEntity> updateStatus({
    required String operationId,
    required String serviceOrderId,
    required ServiceOrderStatusEnum status,
  });

  /// `POST /service-orders/:id/quotes/publish` — publish initial quote.
  Future<ServiceOrderEntity> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  });

  /// `POST /service-orders/:id/quotes/revise` — commercial revision.
  Future<ServiceOrderEntity> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  });

  /// `POST /service-orders/:id/quotes/resume-approved-scope`.
  Future<ServiceOrderEntity> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
  });

  /// `POST /service-orders/:id/mark-ready`.
  Future<ServiceOrderEntity> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  });

  /// `POST /service-orders/:id/mark-delivered`.
  Future<ServiceOrderEntity> markDelivered({
    required String operationId,
    required String serviceOrderId,
  });

  /// `POST /service-orders/:id/not-approved`.
  Future<ServiceOrderEntity> recordNotApproved({
    required String operationId,
    required String serviceOrderId,
  });
}

// ---------------------------------------------------------------------------
// HTTP implementation
// ---------------------------------------------------------------------------

final class StaffSoHttpCommandGateway implements StaffSoCommandGateway {
  const StaffSoHttpCommandGateway(this._client);

  final SessionApiClient _client;

  // ── status transition ───────────────────────────────────────────────────

  @override
  Future<ServiceOrderEntity> updateStatus({
    required String operationId,
    required String serviceOrderId,
    required ServiceOrderStatusEnum status,
  }) async {
    final response = await _client.patchWithHeaders(
      '/service-orders/$serviceOrderId/status',
      headers: {'X-Operation-Id': operationId},
      body: {'status': status.toDbString()},
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  // ── quote commands ──────────────────────────────────────────────────────

  @override
  Future<ServiceOrderEntity> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async {
    final response = await _client.postWithHeaders(
      '/service-orders/$serviceOrderId/quotes/publish',
      headers: {'X-Operation-Id': operationId},
      body: {
        if (changeReason != null && changeReason.trim().isNotEmpty)
          'changeReason': changeReason.trim(),
      },
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  @override
  Future<ServiceOrderEntity> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async {
    final response = await _client.postWithHeaders(
      '/service-orders/$serviceOrderId/quotes/revise',
      headers: {'X-Operation-Id': operationId},
      body: {
        if (changeReason != null && changeReason.trim().isNotEmpty)
          'changeReason': changeReason.trim(),
      },
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  @override
  Future<ServiceOrderEntity> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
  }) async {
    final response = await _client.postWithHeaders(
      '/service-orders/$serviceOrderId/quotes/resume-approved-scope',
      headers: {'X-Operation-Id': operationId},
      body: const {},
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  // ── execution / delivery commands ───────────────────────────────────────

  @override
  Future<ServiceOrderEntity> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async {
    final response = await _client.postWithHeaders(
      '/service-orders/$serviceOrderId/mark-ready',
      headers: {'X-Operation-Id': operationId},
      body: {
        if (notes != null && notes.trim().isNotEmpty) 'notes': notes.trim(),
      },
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  @override
  Future<ServiceOrderEntity> markDelivered({
    required String operationId,
    required String serviceOrderId,
  }) async {
    final response = await _client.postWithHeaders(
      '/service-orders/$serviceOrderId/mark-delivered',
      headers: {'X-Operation-Id': operationId},
      body: const {},
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  @override
  Future<ServiceOrderEntity> recordNotApproved({
    required String operationId,
    required String serviceOrderId,
  }) async {
    final response = await _client.postWithHeaders(
      '/service-orders/$serviceOrderId/not-approved',
      headers: {'X-Operation-Id': operationId},
      body: const {},
    ).timeout(const Duration(seconds: 15));
    final body = _decodeSuccess(response.statusCode, response.body);
    return _fromWire(_requireMap(body['serviceOrder']));
  }

  // ── helpers ─────────────────────────────────────────────────────────────

  static Map<String, dynamic> _decodeSuccess(int statusCode, String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      if (statusCode >= 200 && statusCode < 300) {
        throw const FormatException('Service-order command response is not JSON.');
      }
    }
    if (statusCode < 200 || statusCode >= 300) {
      final error = decoded is Map ? decoded['error'] : null;
      throw StaffSoCommandException(
        statusCode,
        error is String ? error : 'STAFF_SO_COMMAND_FAILED',
      );
    }
    return _requireMap(decoded);
  }

  static Map<String, dynamic> _requireMap(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Service-order payload must be an object.');
    }
    return value;
  }

  static ServiceOrderEntity _fromWire(Map<String, dynamic> wire) {
    return ServiceOrderEntity.fromMap({
      'id': wire['id'],
      'friendly_id': wire['friendlyId'],
      'customer_id': wire['customerId'],
      'equipment_id': wire['equipmentId'],
      'technician_id': wire['technicianId'],
      'status': wire['status'],
      'problem_description': wire['problemDescription'],
      'diagnosis': wire['diagnosis'],
      'solution': wire['solution'],
      'total_amount_minor': wire['totalAmountMinor'] ?? wire['totalAmount'],
      'updated_at': wire['updatedAt'],
    });
  }
}
