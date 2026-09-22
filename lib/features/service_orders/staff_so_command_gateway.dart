import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:assistailab/core/commands/command_failure.dart';
import 'package:assistailab/features/auth/application/session_api_client.dart';

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

String? normalizeReason(String? reason) {
  if (reason == null) return null;
  final trimmed = reason.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > 1000) {
    throw ArgumentError.value(
      reason,
      'reason',
      'Reason must be at most 1000 characters.',
    );
  }
  return trimmed;
}

String? normalizeDiagnosis(String? diagnosis) {
  if (diagnosis == null) return null;
  final trimmed = diagnosis.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > 20000) {
    throw ArgumentError.value(
      diagnosis,
      'diagnosis',
      'Diagnosis must be at most 20000 characters.',
    );
  }
  return trimmed;
}

String? normalizeNotes(String? notes) {
  if (notes == null) return null;
  final trimmed = notes.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > 1000) {
    throw ArgumentError.value(
      notes,
      'notes',
      'Notes must be at most 1000 characters.',
    );
  }
  return trimmed;
}

/// Specialized exception thrown by staff SO command operations.
final class StaffSoCommandException extends CommandException {
  const StaffSoCommandException(
    super.statusCode,
    super.errorCode, {
    this.safeMessage,
  });

  final String? safeMessage;

  @override
  String get message {
    final explicit = safeMessage;
    if (explicit != null) return explicit;
    return switch (errorCode) {
      'STAFF_UNAUTHENTICATED' =>
        'Autenticação necessária para executar esta operação.',
      'STAFF_CONTEXT_REQUIRED' =>
        'Apenas equipe autorizada pode executar esta operação.',
      'STAFF_ROLE_REQUIRED' =>
        'Apenas administradores e técnicos podem executar esta operação.',
      'STAFF_COMMAND_REQUIRES_ONLINE_SESSION' =>
        'Conecte-se à internet para executar esta operação.',
      _ => 'Falha ao executar comando de Ordem de Serviço.',
    };
  }
}

final class StaffServiceOrderProjection {
  const StaffServiceOrderProjection({
    required this.serviceOrderId,
    required this.wire,
  });

  final String serviceOrderId;
  final Map<String, dynamic> wire;
}

final class StaffSoQuoteRevisionItem {
  const StaffSoQuoteRevisionItem({
    this.id,
    this.partId,
    required this.description,
    required this.quantity,
    required this.unitPriceMinor,
  });

  final String? id;
  final String? partId;
  final String description;
  final int quantity;
  final int unitPriceMinor;

  factory StaffSoQuoteRevisionItem.fromMap(Map<String, dynamic> map) {
    final expectedKeys = <String>{
      if (map.containsKey('id')) 'id',
      if (map.containsKey('partId')) 'partId',
      'description',
      'quantity',
      'unitPriceMinor',
    };
    if (map.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(map.keys.toSet()).isNotEmpty) {
      throw const FormatException('Unexpected revision item keys.');
    }
    final rawId = map['id'];
    if (rawId != null && (rawId is! String || !_uuidPattern.hasMatch(rawId))) {
      throw const FormatException('Invalid revision item id.');
    }
    final rawPartId = map['partId'];
    if (rawPartId != null &&
        (rawPartId is! String || !_uuidPattern.hasMatch(rawPartId))) {
      throw const FormatException('Invalid revision item partId.');
    }
    final rawDesc = map['description'];
    if (rawDesc is! String ||
        rawDesc.trim() != rawDesc ||
        rawDesc.isEmpty ||
        rawDesc.length > 1000) {
      throw const FormatException('Invalid revision item description.');
    }
    final rawQty = map['quantity'];
    if (rawQty is! int || rawQty < 1 || rawQty > 100000) {
      throw const FormatException('Invalid revision item quantity.');
    }
    final rawUnitPrice = map['unitPriceMinor'];
    if (rawUnitPrice is! int || rawUnitPrice < 0 || rawUnitPrice > 9999999999) {
      throw const FormatException('Invalid revision item unitPriceMinor.');
    }
    return StaffSoQuoteRevisionItem(
      id: rawId,
      partId: rawPartId,
      description: rawDesc,
      quantity: rawQty,
      unitPriceMinor: rawUnitPrice,
    );
  }

  Map<String, Object?> toMap() => {
        'description': description,
        if (id != null) 'id': id,
        if (partId != null) 'partId': partId,
        'quantity': quantity,
        'unitPriceMinor': unitPriceMinor,
      };

  Map<String, dynamic> toWire() => {
        if (id != null) 'id': id,
        if (partId != null) 'partId': partId,
        'description': description,
        'quantity': quantity,
        'unitPriceMinor': unitPriceMinor,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StaffSoQuoteRevisionItem &&
          id == other.id &&
          partId == other.partId &&
          description == other.description &&
          quantity == other.quantity &&
          unitPriceMinor == other.unitPriceMinor;

  @override
  int get hashCode =>
      Object.hash(id, partId, description, quantity, unitPriceMinor);
}

typedef StaffSoGet = Future<http.Response> Function(String endpoint);
typedef StaffSoPost = Future<http.Response> Function(
  String endpoint, {
  Map<String, dynamic>? body,
  Map<String, String> headers,
});

abstract interface class StaffSoCommandGateway {
  Future<void> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  });

  Future<void> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    required String? diagnosis,
    required List<StaffSoQuoteRevisionItem> items,
    required String changeReason,
  });

  Future<void> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
    required String reason,
  });

  Future<void> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  });

  Future<void> markDelivered({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  });

  Future<StaffServiceOrderProjection> readProjection(String serviceOrderId);
}

final class StaffSoHttpCommandGateway implements StaffSoCommandGateway {
  StaffSoHttpCommandGateway(SessionApiClient client)
      : this.forTesting(get: client.get, post: client.postWithHeaders);

  const StaffSoHttpCommandGateway.forTesting({
    required StaffSoGet get,
    required StaffSoPost post,
  })  : _get = get,
        _post = post;

  final StaffSoGet _get;
  final StaffSoPost _post;

  static const _timeout = Duration(seconds: 15);

  @override
  Future<void> publishInitialQuote({
    required String operationId,
    required String serviceOrderId,
    String? changeReason,
  }) async {
    final normalized = normalizeReason(changeReason);
    final response = await _post(
      '/service-orders/$serviceOrderId/quotes/publish',
      headers: {'X-Operation-Id': operationId},
      body: {
        if (normalized != null) 'changeReason': normalized,
      },
    ).timeout(_timeout);
    _decodeSuccess(response);
  }

  @override
  Future<void> publishCommercialRevision({
    required String operationId,
    required String serviceOrderId,
    required String? diagnosis,
    required List<StaffSoQuoteRevisionItem> items,
    required String changeReason,
  }) async {
    final normalizedDiag = normalizeDiagnosis(diagnosis);
    final normalizedReason = normalizeReason(changeReason);
    if (normalizedReason == null) {
      throw ArgumentError.value(
        changeReason,
        'changeReason',
        'changeReason is required for quote revision.',
      );
    }
    final response = await _post(
      '/service-orders/$serviceOrderId/quotes/revise',
      headers: {'X-Operation-Id': operationId},
      body: {
        'diagnosis': normalizedDiag,
        'items': items.map((item) => item.toWire()).toList(growable: false),
        'changeReason': normalizedReason,
      },
    ).timeout(_timeout);
    _decodeSuccess(response);
  }

  @override
  Future<void> resumeApprovedScope({
    required String operationId,
    required String serviceOrderId,
    required String reason,
  }) async {
    final normalizedReason = normalizeReason(reason);
    if (normalizedReason == null) {
      throw ArgumentError.value(
        reason,
        'reason',
        'reason is required to resume approved scope.',
      );
    }
    final response = await _post(
      '/service-orders/$serviceOrderId/quotes/resume-approved-scope',
      headers: {'X-Operation-Id': operationId},
      body: {'reason': normalizedReason},
    ).timeout(_timeout);
    _decodeSuccess(response);
  }

  @override
  Future<void> markReady({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async {
    final normalized = normalizeNotes(notes);
    final response = await _post(
      '/service-orders/$serviceOrderId/mark-ready',
      headers: {'X-Operation-Id': operationId},
      body: {
        if (normalized != null) 'notes': normalized,
      },
    ).timeout(_timeout);
    _decodeSuccess(response);
  }

  @override
  Future<void> markDelivered({
    required String operationId,
    required String serviceOrderId,
    String? notes,
  }) async {
    final normalized = normalizeNotes(notes);
    final response = await _post(
      '/service-orders/$serviceOrderId/mark-delivered',
      headers: {'X-Operation-Id': operationId},
      body: {
        if (normalized != null) 'notes': normalized,
      },
    ).timeout(_timeout);
    _decodeSuccess(response);
  }

  @override
  Future<StaffServiceOrderProjection> readProjection(
    String serviceOrderId,
  ) async {
    final response = await _get(
      '/service-orders/$serviceOrderId/projection',
    ).timeout(_timeout);
    final decoded = _decodeSuccess(response);
    if (decoded['id'] != serviceOrderId || decoded['contractVersion'] != 2) {
      throw const StaffSoCommandException(
        502,
        'STAFF_PROJECTION_RESPONSE_INVALID',
      );
    }
    return StaffServiceOrderProjection(
      serviceOrderId: serviceOrderId,
      wire: Map.unmodifiable(decoded),
    );
  }

  static Map<String, dynamic> _decodeSuccess(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const StaffSoCommandException(
          502,
          'STAFF_COMMAND_RESPONSE_INVALID',
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded is Map ? decoded['error'] : null;
      throw StaffSoCommandException(
        response.statusCode,
        code is String ? code : 'STAFF_COMMAND_FAILED',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const StaffSoCommandException(
        502,
        'STAFF_COMMAND_RESPONSE_INVALID',
      );
    }
    return decoded;
  }
}
