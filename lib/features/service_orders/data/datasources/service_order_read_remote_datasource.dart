import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../../auth/application/session_api_client.dart';
import '../../../auth/domain/entities/auth_scope.dart';
import '../dtos/service_order_read_dto.dart';

enum ServiceOrderReadFailureKind {
  unauthorized,
  forbidden,
  notFound,
  conflict,
  unprocessable,
  server,
  timeout,
  invalidPayload,
  other,
}

final class ServiceOrderReadException implements Exception {
  const ServiceOrderReadException({
    required this.kind,
    required this.code,
    this.statusCode,
  });

  final ServiceOrderReadFailureKind kind;
  final String code;
  final int? statusCode;

  @override
  String toString() => 'ServiceOrderReadException($kind, $statusCode): $code';
}

typedef ServiceOrderReadGet = Future<http.Response> Function(String endpoint);

abstract interface class ServiceOrderReadRemoteDataSource {
  Future<List<ServiceOrderAdministrativeDto>> readAdministrativeList(
    ProfessionalAuthScope scope,
  );

  Future<ServiceOrderAdministrativeDto> readAdministrativeDetail(
    String serviceOrderId,
    ProfessionalAuthScope scope,
  );

  Future<ServiceOrderProjectionDto> readProjection(
    String serviceOrderId, {
    required ServiceOrderProjectionAudience audience,
  });
}

/// HTTP read boundary only. It never receives a database handle and therefore
/// cannot turn GET responses into a competing synchronization mechanism.
final class HttpServiceOrderReadRemoteDataSource
    implements ServiceOrderReadRemoteDataSource {
  HttpServiceOrderReadRemoteDataSource(SessionApiClient client)
      : this.forTesting(get: client.get);

  const HttpServiceOrderReadRemoteDataSource.forTesting({
    required ServiceOrderReadGet get,
    this.timeout = const Duration(seconds: 15),
  }) : _get = get;

  final ServiceOrderReadGet _get;
  final Duration timeout;

  @override
  Future<List<ServiceOrderAdministrativeDto>> readAdministrativeList(
    ProfessionalAuthScope scope,
  ) async {
    _validateProfessionalScope(scope);
    final body = await _readJson('/service-orders');
    try {
      return ServiceOrderAdministrativeDto.listFromEnvelope(body);
    } on Object catch (error) {
      throw _invalidPayload(error);
    }
  }

  @override
  Future<ServiceOrderAdministrativeDto> readAdministrativeDetail(
    String serviceOrderId,
    ProfessionalAuthScope scope,
  ) async {
    _validateProfessionalScope(scope);
    _validateId(serviceOrderId);
    final body = await _readJson('/service-orders/$serviceOrderId');
    try {
      final dto = ServiceOrderAdministrativeDto.detailFromEnvelope(body);
      if (dto.id != serviceOrderId) {
        throw const FormatException('Detail service-order id does not match.');
      }
      return dto;
    } on Object catch (error) {
      throw _invalidPayload(error);
    }
  }

  @override
  Future<ServiceOrderProjectionDto> readProjection(
    String serviceOrderId, {
    required ServiceOrderProjectionAudience audience,
  }) async {
    _validateId(serviceOrderId);
    final body = await _readJson(
      '/service-orders/$serviceOrderId/projection',
    );
    try {
      return ServiceOrderProjectionDto.fromWire(
        body,
        audience: audience,
        expectedServiceOrderId: serviceOrderId,
      );
    } on Object catch (error) {
      throw _invalidPayload(error);
    }
  }

  Future<Map<String, dynamic>> _readJson(String endpoint) async {
    late http.Response response;
    try {
      response = await _get(endpoint).timeout(timeout);
    } on TimeoutException {
      throw const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.timeout,
        code: 'SERVICE_ORDER_READ_TIMEOUT',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const ServiceOrderReadException(
          kind: ServiceOrderReadFailureKind.invalidPayload,
          code: 'SERVICE_ORDER_READ_RESPONSE_INVALID',
          statusCode: 502,
        );
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final serverCode = decoded is Map ? decoded['error'] : null;
      throw ServiceOrderReadException(
        kind: _failureKind(response.statusCode),
        code: serverCode is String ? serverCode : 'SERVICE_ORDER_READ_FAILED',
        statusCode: response.statusCode,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.invalidPayload,
        code: 'SERVICE_ORDER_READ_RESPONSE_INVALID',
        statusCode: 502,
      );
    }
    return decoded;
  }

  static ServiceOrderReadException _invalidPayload(Object _) =>
      const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.invalidPayload,
        code: 'SERVICE_ORDER_READ_RESPONSE_INVALID',
        statusCode: 502,
      );

  static ServiceOrderReadFailureKind _failureKind(int statusCode) =>
      switch (statusCode) {
        401 => ServiceOrderReadFailureKind.unauthorized,
        403 => ServiceOrderReadFailureKind.forbidden,
        404 => ServiceOrderReadFailureKind.notFound,
        409 => ServiceOrderReadFailureKind.conflict,
        422 => ServiceOrderReadFailureKind.unprocessable,
        >= 500 => ServiceOrderReadFailureKind.server,
        _ => ServiceOrderReadFailureKind.other,
      };

  static void _validateId(String serviceOrderId) {
    if (!Uuid.isValidUUID(fromString: serviceOrderId)) {
      throw ArgumentError.value(
        serviceOrderId,
        'serviceOrderId',
        'Must be a UUID.',
      );
    }
  }

  static void _validateProfessionalScope(ProfessionalAuthScope scope) {
    if (scope.userId.trim().isEmpty || scope.organizationId.trim().isEmpty) {
      throw StateError('A valid professional scope is required.');
    }
  }
}
