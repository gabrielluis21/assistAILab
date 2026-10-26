import 'package:sqflite/sqflite.dart';

import '../../core/commands/command_executor.dart';
import '../../core/commands/command_intent.dart';
import 'equipment_acquisition_entity.dart';
import 'equipment_acquisition_gateway.dart';
import 'equipment_acquisition_repository.dart';
import 'pre_acquisition_entity.dart';

const equipmentAcquisitionCreateCommandType = 'EQUIPMENT_ACQUISITION_CREATE';
const equipmentAcquisitionAuthorizeCommandType =
    'EQUIPMENT_ACQUISITION_AUTHORIZE';
const equipmentAcquisitionRejectCommandType = 'EQUIPMENT_ACQUISITION_REJECT';
const equipmentAcquisitionAuthorizeInPersonCommandType =
    'EQUIPMENT_ACQUISITION_AUTHORIZE_IN_PERSON';
const equipmentAcquisitionCompleteCommandType =
    'EQUIPMENT_ACQUISITION_COMPLETE';

const equipmentAcquisitionOwnedCommandTypes = <String>{
  equipmentAcquisitionCreateCommandType,
  equipmentAcquisitionAuthorizeCommandType,
  equipmentAcquisitionRejectCommandType,
  equipmentAcquisitionAuthorizeInPersonCommandType,
  equipmentAcquisitionCompleteCommandType,
};

final class EquipmentAcquisitionCommandExecutor {
  const EquipmentAcquisitionCommandExecutor({
    required this.gateway,
    required this.acquisitionRepository,
    required this.intentRepository,
    required this.database,
    required this.isBindingCurrent,
    required this.operationIdFactory,
  });

  final EquipmentAcquisitionGateway gateway;
  final EquipmentAcquisitionRepository acquisitionRepository;
  final CommandIntentRepository intentRepository;
  final Database database;
  final bool Function() isBindingCurrent;
  final String Function() operationIdFactory;

  Future<EquipmentAcquisitionEntity> createFromPreAcquisition({
    required PreAcquisitionEntity preAcquisition,
  }) {
    if (preAcquisition.status != PreAcquisitionStatus.approved) {
      throw StateError('PreAcquisition must be approved before CREATE.');
    }
    final purpose = switch (preAcquisition.purpose) {
      PreAcquisitionPurpose.resale => EquipmentAcquisitionPurpose.resale,
      PreAcquisitionPurpose.partsDonor =>
        EquipmentAcquisitionPurpose.partsDonor,
    };
    final source = preAcquisition.serviceOrderId == null
        ? EquipmentAcquisitionSource.directOffer
        : EquipmentAcquisitionSource.serviceOrder;
    final normalizedNotes =
        normalizeEquipmentAcquisitionNotes(preAcquisition.notes);
    final payload = <String, Object?>{
      'clientPreAcquisitionId': preAcquisition.id,
      'equipmentId': preAcquisition.equipmentId,
      if (normalizedNotes != null) 'notes': normalizedNotes,
      if (preAcquisition.offeredAmountMinor != null)
        'offeredAmountMinor': preAcquisition.offeredAmountMinor,
      'purpose': purpose.wireValue,
      if (preAcquisition.serviceOrderId != null)
        'serviceOrderId': preAcquisition.serviceOrderId,
      'source': source.wireValue,
    };
    return _execute(
      commandType: equipmentAcquisitionCreateCommandType,
      targetId: preAcquisition.id,
      payload: payload,
      dispatch: (operationId) => gateway.create(
        operationId: operationId,
        source: source,
        equipmentId: preAcquisition.equipmentId,
        serviceOrderId: preAcquisition.serviceOrderId,
        purpose: purpose,
        offeredAmountMinor: preAcquisition.offeredAmountMinor,
        notes: normalizedNotes,
        clientPreAcquisitionId: preAcquisition.id,
      ),
      validate: (authoritative) {
        if (authoritative.equipmentId != preAcquisition.equipmentId ||
            authoritative.customerId != preAcquisition.customerId ||
            authoritative.organizationId != preAcquisition.organizationId ||
            authoritative.serviceOrderId != preAcquisition.serviceOrderId ||
            authoritative.source != source ||
            authoritative.clientPreAcquisitionId != preAcquisition.id ||
            authoritative.purpose != purpose ||
            authoritative.status != EquipmentAcquisitionStatus.pending) {
          throw const EquipmentAcquisitionCommandException(
            502,
            'EQUIPMENT_ACQUISITION_RESPONSE_MISMATCH',
          );
        }
      },
      authoritativeCommit: (executor, authoritative) =>
          acquisitionRepository.upsert(authoritative, executor: executor),
    );
  }

  Future<EquipmentAcquisitionEntity> authorize({
    required String acquisitionId,
    required EquipmentConsentMethod consentMethod,
  }) {
    if (!consentMethod.isCustomerSelectable) {
      throw ArgumentError.value(
        consentMethod,
        'consentMethod',
        'IN_PERSON_ASSISTED is restricted to staff.',
      );
    }
    return _transition(
      commandType: equipmentAcquisitionAuthorizeCommandType,
      acquisitionId: acquisitionId,
      payload: {
        'acquisitionId': acquisitionId,
        'consentMethod': consentMethod.wireValue,
      },
      dispatch: (operationId) => gateway.authorize(
        operationId: operationId,
        acquisitionId: acquisitionId,
        consentMethod: consentMethod,
      ),
      validate: (authoritative) {
        if (authoritative.status != EquipmentAcquisitionStatus.authorized ||
            authoritative.consentMethod != consentMethod) {
          throw const EquipmentAcquisitionCommandException(
            502,
            'EQUIPMENT_ACQUISITION_RESPONSE_MISMATCH',
          );
        }
      },
    );
  }

  Future<EquipmentAcquisitionEntity> reject({
    required String acquisitionId,
  }) =>
      _transition(
        commandType: equipmentAcquisitionRejectCommandType,
        acquisitionId: acquisitionId,
        payload: {'acquisitionId': acquisitionId},
        dispatch: (operationId) => gateway.reject(
          operationId: operationId,
          acquisitionId: acquisitionId,
        ),
        validate: (authoritative) {
          if (authoritative.status != EquipmentAcquisitionStatus.rejected) {
            throw const EquipmentAcquisitionCommandException(
              502,
              'EQUIPMENT_ACQUISITION_RESPONSE_MISMATCH',
            );
          }
        },
      );

  Future<EquipmentAcquisitionEntity> authorizeInPerson({
    required String acquisitionId,
  }) =>
      _transition(
        commandType: equipmentAcquisitionAuthorizeInPersonCommandType,
        acquisitionId: acquisitionId,
        payload: {
          'acquisitionId': acquisitionId,
          'consentMethod': EquipmentConsentMethod.inPersonAssisted.wireValue,
        },
        dispatch: (operationId) => gateway.authorizeInPerson(
          operationId: operationId,
          acquisitionId: acquisitionId,
        ),
        validate: (authoritative) {
          if (authoritative.source != EquipmentAcquisitionSource.directOffer ||
              authoritative.status != EquipmentAcquisitionStatus.authorized ||
              authoritative.consentMethod !=
                  EquipmentConsentMethod.inPersonAssisted) {
            throw const EquipmentAcquisitionCommandException(
              502,
              'EQUIPMENT_ACQUISITION_RESPONSE_MISMATCH',
            );
          }
        },
      );

  Future<EquipmentAcquisitionEntity> complete({
    required String acquisitionId,
  }) =>
      _transition(
        commandType: equipmentAcquisitionCompleteCommandType,
        acquisitionId: acquisitionId,
        payload: {'acquisitionId': acquisitionId},
        dispatch: (operationId) => gateway.complete(
          operationId: operationId,
          acquisitionId: acquisitionId,
        ),
        validate: (authoritative) {
          if (authoritative.status != EquipmentAcquisitionStatus.completed) {
            throw const EquipmentAcquisitionCommandException(
              502,
              'EQUIPMENT_ACQUISITION_RESPONSE_MISMATCH',
            );
          }
        },
      );

  Future<EquipmentAcquisitionEntity> _transition({
    required String commandType,
    required String acquisitionId,
    required Map<String, Object?> payload,
    required Future<EquipmentAcquisitionEntity> Function(String operationId)
        dispatch,
    required void Function(EquipmentAcquisitionEntity authoritative) validate,
  }) async {
    final expected = await acquisitionRepository.findById(
      acquisitionId,
      executor: database,
    );
    if (!isBindingCurrent()) {
      throw StateError(
        'Equipment acquisition command belongs to a stale session.',
      );
    }
    if (expected == null) {
      throw StateError('EquipmentAcquisition projection does not exist.');
    }
    return _execute(
      commandType: commandType,
      targetId: acquisitionId,
      payload: payload,
      dispatch: dispatch,
      validate: (authoritative) {
        if (authoritative.id != acquisitionId ||
            authoritative.equipmentId != expected.equipmentId ||
            authoritative.customerId != expected.customerId ||
            authoritative.organizationId != expected.organizationId ||
            authoritative.serviceOrderId != expected.serviceOrderId ||
            authoritative.source != expected.source ||
            authoritative.clientPreAcquisitionId !=
                expected.clientPreAcquisitionId ||
            authoritative.purpose != expected.purpose) {
          throw const EquipmentAcquisitionCommandException(
            502,
            'EQUIPMENT_ACQUISITION_RESPONSE_MISMATCH',
          );
        }
        validate(authoritative);
      },
      authoritativeCommit: (executor, authoritative) =>
          acquisitionRepository.upsert(
        authoritative,
        executor: executor,
      ),
    );
  }

  Future<EquipmentAcquisitionEntity> _execute({
    required String commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required Future<EquipmentAcquisitionEntity> Function(String operationId)
        dispatch,
    required void Function(EquipmentAcquisitionEntity authoritative) validate,
    required Future<void> Function(
      DatabaseExecutor executor,
      EquipmentAcquisitionEntity authoritative,
    ) authoritativeCommit,
  }) async {
    await _assertReplayCompatible(
      commandType: commandType,
      targetId: targetId,
      payload: payload,
    );
    return CommandExecutor(
      intentRepository: intentRepository,
      database: database,
      isBindingCurrent: isBindingCurrent,
      operationIdFactory: operationIdFactory,
    ).execute(
      commandType: commandType,
      targetId: targetId,
      payload: payload,
      dispatch: (operationId) async {
        final authoritative = await dispatch(operationId);
        if (!isBindingCurrent()) {
          throw StateError(
            'Equipment acquisition command belongs to a stale session.',
          );
        }
        validate(authoritative);
        return authoritative;
      },
      authoritativeCommit: authoritativeCommit,
    );
  }

  Future<void> _assertReplayCompatible({
    required String commandType,
    required String targetId,
    required Map<String, Object?> payload,
  }) async {
    if (!isBindingCurrent()) {
      throw StateError(
        'Equipment acquisition command belongs to a stale session.',
      );
    }
    final unresolved = await intentRepository.findUnresolved(
      commandType: commandType,
      targetId: targetId,
      executor: database,
    );
    if (!isBindingCurrent()) {
      throw StateError(
        'Equipment acquisition command belongs to a stale session.',
      );
    }
    if (unresolved.length > 1) {
      throw StateError('Ambiguous unresolved EquipmentAcquisition command.');
    }
    if (unresolved.isEmpty) return;
    final existing = unresolved.single;
    if (existing.lifecycle == CommandIntentLifecycle.sending) {
      throw StateError('A matching EquipmentAcquisition command is in flight.');
    }
    if (existing.canonicalPayload != canonicalCommandPayload(payload)) {
      throw StateError(
        'An unresolved EquipmentAcquisition command has another identity.',
      );
    }
  }
}
