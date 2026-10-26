import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/commands/command_failure.dart';
import '../auth/application/session_api_client.dart';
import 'equipment_acquisition_entity.dart';

typedef EquipmentAcquisitionGet = Future<http.Response> Function(
  String endpoint,
);
typedef EquipmentAcquisitionPost = Future<http.Response> Function(
  String endpoint, {
  Map<String, dynamic>? body,
  Map<String, String> headers,
});

final class EquipmentAcquisitionCommandException extends CommandException {
  const EquipmentAcquisitionCommandException(
    super.statusCode,
    super.errorCode, {
    this.safeMessage,
  });

  final String? safeMessage;

  @override
  String get message => safeMessage ?? switch (errorCode) {
        'EQUIPMENT_ACTIVE_ACQUISITION_EXISTS' =>
          'Este equipamento já possui uma aquisição ativa.',
        'SERVICE_ORDER_NOT_AVAILABLE' =>
          'A Ordem de Serviço não está disponível para esta aquisição.',
        'ACQUISITION_NOT_PENDING' =>
          'A aquisição não está mais pendente.',
        'ACQUISITION_NOT_AUTHORIZED' =>
          'A aquisição ainda não foi autorizada.',
        'EQUIPMENT_OWNERSHIP_CONFLICT' =>
          'A titularidade do equipamento mudou. Atualize os dados.',
        _ => 'Não foi possível concluir a operação de aquisição.',
      };
}

abstract interface class EquipmentAcquisitionGateway {
  Future<List<EquipmentAcquisitionEntity>> listAll();

  Future<EquipmentAcquisitionEntity> create({
    required String operationId,
    required EquipmentAcquisitionSource source,
    required String equipmentId,
    required String? serviceOrderId,
    required EquipmentAcquisitionPurpose purpose,
    required int? offeredAmountMinor,
    required String? notes,
    required String clientPreAcquisitionId,
  });

  Future<EquipmentAcquisitionEntity> authorize({
    required String operationId,
    required String acquisitionId,
    required EquipmentConsentMethod consentMethod,
  });

  Future<EquipmentAcquisitionEntity> reject({
    required String operationId,
    required String acquisitionId,
  });

  Future<EquipmentAcquisitionEntity> authorizeInPerson({
    required String operationId,
    required String acquisitionId,
  });

  Future<EquipmentAcquisitionEntity> complete({
    required String operationId,
    required String acquisitionId,
  });
}

final class EquipmentAcquisitionHttpGateway
    implements EquipmentAcquisitionGateway {
  EquipmentAcquisitionHttpGateway(SessionApiClient client)
      : this.forTesting(
          get: client.get,
          post: client.postWithHeaders,
        );

  const EquipmentAcquisitionHttpGateway.forTesting({
    required EquipmentAcquisitionGet get,
    required EquipmentAcquisitionPost post,
  })  : _get = get,
        _post = post;

  final EquipmentAcquisitionGet _get;
  final EquipmentAcquisitionPost _post;

  @override
  Future<List<EquipmentAcquisitionEntity>> listAll() async {
    final response = await _get('/equipment-acquisitions')
        .timeout(const Duration(seconds: 15));
    final body = _decode(response);
    final acquisitions = body['acquisitions'];
    if (acquisitions is! List) {
      throw const EquipmentAcquisitionCommandException(
        502,
        'EQUIPMENT_ACQUISITION_RESPONSE_INVALID',
      );
    }
    try {
      return acquisitions
          .map((value) => EquipmentAcquisitionEntity.fromWire(
                _requireMap(value),
              ))
          .toList(growable: false);
    } on Object {
      throw const EquipmentAcquisitionCommandException(
        502,
        'EQUIPMENT_ACQUISITION_RESPONSE_INVALID',
      );
    }
  }

  @override
  Future<EquipmentAcquisitionEntity> create({
    required String operationId,
    required EquipmentAcquisitionSource source,
    required String equipmentId,
    required String? serviceOrderId,
    required EquipmentAcquisitionPurpose purpose,
    required int? offeredAmountMinor,
    required String? notes,
    required String clientPreAcquisitionId,
  }) async {
    _validateCreateInput(
      source: source,
      serviceOrderId: serviceOrderId,
      offeredAmountMinor: offeredAmountMinor,
      notes: notes,
    );
    final normalizedNotes = normalizeEquipmentAcquisitionNotes(notes);
    final endpoint = source == EquipmentAcquisitionSource.serviceOrder
        ? '/equipment-acquisitions'
        : '/equipment-acquisitions/direct-offer';
    return _mutation(
      endpoint,
      operationId: operationId,
      body: {
        'source': source.wireValue,
        'equipmentId': equipmentId,
        if (source == EquipmentAcquisitionSource.serviceOrder)
          'serviceOrderId': serviceOrderId,
        'purpose': purpose.wireValue,
        if (offeredAmountMinor != null)
          'offeredAmountMinor': offeredAmountMinor,
        if (normalizedNotes != null) 'notes': normalizedNotes,
        'clientPreAcquisitionId': clientPreAcquisitionId,
      },
    );
  }

  @override
  Future<EquipmentAcquisitionEntity> authorize({
    required String operationId,
    required String acquisitionId,
    required EquipmentConsentMethod consentMethod,
  }) {
    if (!consentMethod.isCustomerSelectable) {
      throw ArgumentError.value(
        consentMethod,
        'consentMethod',
        'IN_PERSON_ASSISTED is restricted to staff-assisted authorization.',
      );
    }
    return _mutation(
      '/equipment-acquisitions/$acquisitionId/authorize',
      operationId: operationId,
      body: {'consentMethod': consentMethod.wireValue},
    );
  }

  @override
  Future<EquipmentAcquisitionEntity> reject({
    required String operationId,
    required String acquisitionId,
  }) =>
      _mutation(
        '/equipment-acquisitions/$acquisitionId/reject',
        operationId: operationId,
        body: const {},
      );

  @override
  Future<EquipmentAcquisitionEntity> authorizeInPerson({
    required String operationId,
    required String acquisitionId,
  }) =>
      _mutation(
        '/equipment-acquisitions/$acquisitionId/authorize-in-person',
        operationId: operationId,
        body: const {
          'consentMethod': 'IN_PERSON_ASSISTED',
        },
      );

  @override
  Future<EquipmentAcquisitionEntity> complete({
    required String operationId,
    required String acquisitionId,
  }) =>
      _mutation(
        '/equipment-acquisitions/$acquisitionId/complete',
        operationId: operationId,
        body: const {},
      );

  Future<EquipmentAcquisitionEntity> _mutation(
    String endpoint, {
    required String operationId,
    required Map<String, dynamic> body,
  }) async {
    final response = await _post(
      endpoint,
      headers: {'X-Operation-Id': operationId},
      body: body,
    ).timeout(const Duration(seconds: 15));
    final decoded = _decode(response);
    try {
      return EquipmentAcquisitionEntity.fromWire(
        _requireMap(decoded['acquisition']),
      );
    } on Object {
      throw const EquipmentAcquisitionCommandException(
        502,
        'EQUIPMENT_ACQUISITION_RESPONSE_INVALID',
      );
    }
  }

  static Map<String, dynamic> _decode(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      if (response.statusCode >= 200 && response.statusCode < 300) {
        throw const EquipmentAcquisitionCommandException(
          502,
          'EQUIPMENT_ACQUISITION_RESPONSE_INVALID',
        );
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final code = decoded is Map ? decoded['error'] : null;
      throw EquipmentAcquisitionCommandException(
        response.statusCode,
        code is String ? code : 'EQUIPMENT_ACQUISITION_COMMAND_FAILED',
      );
    }
    try {
      return _requireMap(decoded);
    } on FormatException {
      throw const EquipmentAcquisitionCommandException(
        502,
        'EQUIPMENT_ACQUISITION_RESPONSE_INVALID',
      );
    }
  }

  static Map<String, dynamic> _requireMap(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Acquisition payload must be an object.');
    }
    return value;
  }
}

String? normalizeEquipmentAcquisitionNotes(String? notes) {
  final normalized = notes?.trim();
  if (normalized == null || normalized.isEmpty) return null;
  if (normalized.length > 5000) {
    throw ArgumentError.value(
      notes,
      'notes',
      'Notes must be at most 5000 characters.',
    );
  }
  return normalized;
}

void _validateCreateInput({
  required EquipmentAcquisitionSource source,
  required String? serviceOrderId,
  required int? offeredAmountMinor,
  required String? notes,
}) {
  if (source == EquipmentAcquisitionSource.serviceOrder &&
      (serviceOrderId == null || serviceOrderId.isEmpty)) {
    throw ArgumentError.value(
      serviceOrderId,
      'serviceOrderId',
      'SERVICE_ORDER requires serviceOrderId.',
    );
  }
  if (source == EquipmentAcquisitionSource.directOffer &&
      serviceOrderId != null) {
    throw ArgumentError.value(
      serviceOrderId,
      'serviceOrderId',
      'DIRECT_OFFER forbids serviceOrderId.',
    );
  }
  if (offeredAmountMinor != null &&
      (offeredAmountMinor < 1 || offeredAmountMinor > 9999999999)) {
    throw ArgumentError.value(
      offeredAmountMinor,
      'offeredAmountMinor',
      'Must be between 1 and 9999999999.',
    );
  }
  normalizeEquipmentAcquisitionNotes(notes);
}
