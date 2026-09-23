import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_provider.dart';
import '../../auth/application/session_api_client.dart';
import '../../auth/domain/entities/auth_scope.dart';
import '../data/datasources/service_order_read_remote_datasource.dart';
import '../data/dtos/service_order_read_dto.dart';

final serviceOrderReadRemoteDataSourceProvider =
    Provider<ServiceOrderReadRemoteDataSource>(
  (ref) => HttpServiceOrderReadRemoteDataSource(
    ref.watch(sessionApiClientProvider),
  ),
);

/// A session-bound, read-only coordinator. Results are transient by design:
/// SQLite remains the operational UI source and Sync Pull remains convergence.
final class ServiceOrderRemoteReader {
  const ServiceOrderRemoteReader({
    required this.scope,
    required this.remote,
    required this.isBindingCurrent,
  });

  final AuthScope scope;
  final ServiceOrderReadRemoteDataSource remote;
  final bool Function() isBindingCurrent;

  Future<List<ServiceOrderAdministrativeDto>> readAdministrativeList() async {
    final professionalScope = _requireProfessionalScope();
    _ensureBindingCurrent();
    final result = await remote.readAdministrativeList(professionalScope);
    _ensureBindingCurrent();
    if (result.any(
      (order) => order.organizationId != professionalScope.organizationId,
    )) {
      throw const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.invalidPayload,
        code: 'SERVICE_ORDER_TENANT_RESPONSE_MISMATCH',
        statusCode: 502,
      );
    }
    return result;
  }

  Future<ServiceOrderAdministrativeDto> readAdministrativeDetail(
    String serviceOrderId,
  ) async {
    final professionalScope = _requireProfessionalScope();
    _ensureBindingCurrent();
    final result = await remote.readAdministrativeDetail(
      serviceOrderId,
      professionalScope,
    );
    _ensureBindingCurrent();
    if (result.organizationId != professionalScope.organizationId) {
      throw const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.invalidPayload,
        code: 'SERVICE_ORDER_TENANT_RESPONSE_MISMATCH',
        statusCode: 502,
      );
    }
    return result;
  }

  Future<ServiceOrderProjectionDto> readProjection(
    String serviceOrderId,
  ) async {
    _ensureBindingCurrent();
    final ServiceOrderProjectionAudience audience;
    if (scope is ProfessionalAuthScope) {
      audience = ServiceOrderProjectionAudience.staff;
    } else if (scope is CustomerAuthScope) {
      audience = ServiceOrderProjectionAudience.customer;
    } else {
      throw StateError(
        'Invalid authorization scope cannot read service orders.',
      );
    }
    final result = await remote.readProjection(
      serviceOrderId,
      audience: audience,
    );
    _ensureBindingCurrent();
    if (scope is ProfessionalAuthScope &&
        result.organizationId !=
            (scope as ProfessionalAuthScope).organizationId) {
      throw const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.invalidPayload,
        code: 'SERVICE_ORDER_TENANT_RESPONSE_MISMATCH',
        statusCode: 502,
      );
    }
    return result;
  }

  ProfessionalAuthScope _requireProfessionalScope() {
    final currentScope = scope;
    if (currentScope is! ProfessionalAuthScope) {
      throw const ServiceOrderReadException(
        kind: ServiceOrderReadFailureKind.forbidden,
        code: 'CUSTOMER_ADMINISTRATIVE_READ_FORBIDDEN',
        statusCode: 403,
      );
    }
    return currentScope;
  }

  void _ensureBindingCurrent() {
    if (!isBindingCurrent()) {
      throw const SessionRequestBlockedException(
        'Service-order read completed after its session was invalidated.',
      );
    }
  }
}

final serviceOrderRemoteReaderProvider = Provider<ServiceOrderRemoteReader?>(
  (ref) {
    final sessionKey = ref.watch(authenticatedSessionKeyProvider);
    if (sessionKey == null) return null;
    return ServiceOrderRemoteReader(
      scope: sessionKey.scope,
      remote: ref.watch(serviceOrderReadRemoteDataSourceProvider),
      isBindingCurrent: () =>
          ref.read(authenticatedSessionKeyProvider) == sessionKey,
    );
  },
);
