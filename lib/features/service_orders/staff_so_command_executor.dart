import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/commands/command_executor.dart';
import '../../core/commands/command_failure.dart';
import '../../core/commands/command_intent.dart';
import '../../core/sync/sync_projection_applier.dart';
import 'staff_so_command_gateway.dart';

// ---------------------------------------------------------------------------
// Exactly 5 Cyber-approved STAFF command types
// ---------------------------------------------------------------------------

const staffSoQuotePublishCommandType = 'SERVICE_ORDER_QUOTE_PUBLISH';
const staffSoQuoteReviseCommandType = 'SERVICE_ORDER_QUOTE_REVISE';
const staffSoResumeApprovedScopeCommandType =
    'SERVICE_ORDER_RESUME_APPROVED_SCOPE';
const staffSoMarkReadyCommandType = 'SERVICE_ORDER_MARK_READY';
const staffSoMarkDeliveredCommandType = 'SERVICE_ORDER_MARK_DELIVERED';

const staffSoOwnedCommandTypes = <String>{
  staffSoQuotePublishCommandType,
  staffSoQuoteReviseCommandType,
  staffSoResumeApprovedScopeCommandType,
  staffSoMarkReadyCommandType,
  staffSoMarkDeliveredCommandType,
};

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

// ---------------------------------------------------------------------------
// Reconciliation Uncertainty Exception (does NOT extend CommandException)
// ---------------------------------------------------------------------------

final class StaffSoProjectionUncertaintyException implements Exception {
  const StaffSoProjectionUncertaintyException({
    required this.cause,
    this.safeMessage,
  });

  final Object cause;
  final String? safeMessage;

  String get message {
    final explicit = safeMessage;
    if (explicit != null) return explicit;
    if (cause is StaffSoCommandException) {
      final cmdException = cause as StaffSoCommandException;
      final explicitCauseMessage = cmdException.safeMessage;
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
  String toString() => 'StaffSoProjectionUncertaintyException(cause: $cause)';
}

// ---------------------------------------------------------------------------
// Strict Immutable Command Identities
// ---------------------------------------------------------------------------

sealed class StaffSoCommandIdentity {
  const StaffSoCommandIdentity();

  String get commandType;
  String get serviceOrderId;
  Map<String, Object?> toCanonicalPayload();

  factory StaffSoCommandIdentity.fromIntent(CommandIntent intent) {
    return switch (intent.commandType) {
      staffSoQuotePublishCommandType =>
        StaffSoPublishQuoteIdentity.fromIntent(intent),
      staffSoQuoteReviseCommandType =>
        StaffSoReviseQuoteIdentity.fromIntent(intent),
      staffSoResumeApprovedScopeCommandType =>
        StaffSoResumeScopeIdentity.fromIntent(intent),
      staffSoMarkReadyCommandType =>
        StaffSoMarkReadyIdentity.fromIntent(intent),
      staffSoMarkDeliveredCommandType =>
        StaffSoMarkDeliveredIdentity.fromIntent(intent),
      _ => throw const FormatException('Unexpected STAFF command type.'),
    };
  }
}

final class StaffSoPublishQuoteIdentity extends StaffSoCommandIdentity {
  const StaffSoPublishQuoteIdentity({
    required this.serviceOrderId,
    this.changeReason,
  });

  @override
  final String serviceOrderId;
  final String? changeReason;

  @override
  String get commandType => staffSoQuotePublishCommandType;

  factory StaffSoPublishQuoteIdentity.fromIntent(CommandIntent intent) {
    if (intent.commandType != staffSoQuotePublishCommandType) {
      throw const FormatException('Unexpected STAFF publish command type.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(intent.canonicalPayload);
    } catch (_) {
      throw const FormatException('Malformed STAFF publish payload JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('STAFF publish payload must be a map.');
    }
    final expectedKeys = <String>{
      'serviceOrderId',
      if (decoded.containsKey('changeReason')) 'changeReason',
    };
    if (decoded.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException('Unexpected keys in STAFF publish payload.');
    }
    final serviceOrderId = decoded['serviceOrderId'];
    if (serviceOrderId is! String ||
        serviceOrderId != intent.targetId ||
        !_uuidPattern.hasMatch(serviceOrderId)) {
      throw const FormatException(
        'Invalid serviceOrderId in STAFF publish payload.',
      );
    }
    final rawReason = decoded['changeReason'];
    if (rawReason != null &&
        (rawReason is! String ||
            rawReason.trim() != rawReason ||
            rawReason.isEmpty ||
            rawReason.length > 1000)) {
      throw const FormatException(
        'Invalid changeReason in STAFF publish payload.',
      );
    }
    return StaffSoPublishQuoteIdentity(
      serviceOrderId: serviceOrderId,
      changeReason: rawReason as String?,
    );
  }

  bool matchesRequestedAction({required String? requestedChangeReason}) =>
      changeReason == normalizeReason(requestedChangeReason);

  @override
  Map<String, Object?> toCanonicalPayload() => {
        if (changeReason != null) 'changeReason': changeReason,
        'serviceOrderId': serviceOrderId,
      };
}

final class StaffSoReviseQuoteIdentity extends StaffSoCommandIdentity {
  const StaffSoReviseQuoteIdentity({
    required this.serviceOrderId,
    required this.diagnosis,
    required this.items,
    required this.changeReason,
  });

  @override
  final String serviceOrderId;
  final String? diagnosis;
  final List<StaffSoQuoteRevisionItem> items;
  final String changeReason;

  @override
  String get commandType => staffSoQuoteReviseCommandType;

  factory StaffSoReviseQuoteIdentity.fromIntent(CommandIntent intent) {
    if (intent.commandType != staffSoQuoteReviseCommandType) {
      throw const FormatException('Unexpected STAFF revise command type.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(intent.canonicalPayload);
    } catch (_) {
      throw const FormatException('Malformed STAFF revise payload JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('STAFF revise payload must be a map.');
    }
    final expectedKeys = <String>{
      'changeReason',
      'diagnosis',
      'items',
      'serviceOrderId',
    };
    if (decoded.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException('Unexpected keys in STAFF revise payload.');
    }
    final serviceOrderId = decoded['serviceOrderId'];
    if (serviceOrderId is! String ||
        serviceOrderId != intent.targetId ||
        !_uuidPattern.hasMatch(serviceOrderId)) {
      throw const FormatException(
        'Invalid serviceOrderId in STAFF revise payload.',
      );
    }
    final rawChangeReason = decoded['changeReason'];
    if (rawChangeReason is! String ||
        rawChangeReason.trim() != rawChangeReason ||
        rawChangeReason.isEmpty ||
        rawChangeReason.length > 1000) {
      throw const FormatException(
        'Invalid changeReason in STAFF revise payload.',
      );
    }
    final rawDiagnosis = decoded['diagnosis'];
    if (rawDiagnosis != null &&
        (rawDiagnosis is! String ||
            rawDiagnosis.trim() != rawDiagnosis ||
            rawDiagnosis.isEmpty ||
            rawDiagnosis.length > 20000)) {
      throw const FormatException('Invalid diagnosis in STAFF revise payload.');
    }
    final rawItems = decoded['items'];
    if (rawItems is! List || rawItems.isEmpty || rawItems.length > 200) {
      throw const FormatException(
        'Invalid items list in STAFF revise payload.',
      );
    }
    final items = <StaffSoQuoteRevisionItem>[];
    for (final item in rawItems) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('Malformed item in STAFF revise payload.');
      }
      items.add(StaffSoQuoteRevisionItem.fromMap(item));
    }
    return StaffSoReviseQuoteIdentity(
      serviceOrderId: serviceOrderId,
      diagnosis: rawDiagnosis as String?,
      items: List.unmodifiable(items),
      changeReason: rawChangeReason,
    );
  }

  bool matchesRequestedAction({
    required String? requestedDiagnosis,
    required List<StaffSoQuoteRevisionItem> requestedItems,
    required String requestedChangeReason,
  }) {
    if (diagnosis != normalizeDiagnosis(requestedDiagnosis)) return false;
    if (changeReason != normalizeReason(requestedChangeReason)) return false;
    if (items.length != requestedItems.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (items[i] != requestedItems[i]) return false;
    }
    return true;
  }

  @override
  Map<String, Object?> toCanonicalPayload() => {
        'changeReason': changeReason,
        'diagnosis': diagnosis,
        'items': items.map((i) => i.toMap()).toList(growable: false),
        'serviceOrderId': serviceOrderId,
      };
}

final class StaffSoResumeScopeIdentity extends StaffSoCommandIdentity {
  const StaffSoResumeScopeIdentity({
    required this.serviceOrderId,
    required this.reason,
  });

  @override
  final String serviceOrderId;
  final String reason;

  @override
  String get commandType => staffSoResumeApprovedScopeCommandType;

  factory StaffSoResumeScopeIdentity.fromIntent(CommandIntent intent) {
    if (intent.commandType != staffSoResumeApprovedScopeCommandType) {
      throw const FormatException('Unexpected STAFF resume command type.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(intent.canonicalPayload);
    } catch (_) {
      throw const FormatException('Malformed STAFF resume payload JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('STAFF resume payload must be a map.');
    }
    final expectedKeys = <String>{'reason', 'serviceOrderId'};
    if (decoded.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException('Unexpected keys in STAFF resume payload.');
    }
    final serviceOrderId = decoded['serviceOrderId'];
    if (serviceOrderId is! String ||
        serviceOrderId != intent.targetId ||
        !_uuidPattern.hasMatch(serviceOrderId)) {
      throw const FormatException(
        'Invalid serviceOrderId in STAFF resume payload.',
      );
    }
    final rawReason = decoded['reason'];
    if (rawReason is! String ||
        rawReason.trim() != rawReason ||
        rawReason.isEmpty ||
        rawReason.length > 1000) {
      throw const FormatException('Invalid reason in STAFF resume payload.');
    }
    return StaffSoResumeScopeIdentity(
      serviceOrderId: serviceOrderId,
      reason: rawReason,
    );
  }

  bool matchesRequestedAction({required String requestedReason}) =>
      reason == normalizeReason(requestedReason);

  @override
  Map<String, Object?> toCanonicalPayload() => {
        'reason': reason,
        'serviceOrderId': serviceOrderId,
      };
}

final class StaffSoMarkReadyIdentity extends StaffSoCommandIdentity {
  const StaffSoMarkReadyIdentity({
    required this.serviceOrderId,
    this.notes,
  });

  @override
  final String serviceOrderId;
  final String? notes;

  @override
  String get commandType => staffSoMarkReadyCommandType;

  factory StaffSoMarkReadyIdentity.fromIntent(CommandIntent intent) {
    if (intent.commandType != staffSoMarkReadyCommandType) {
      throw const FormatException('Unexpected STAFF mark ready command type.');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(intent.canonicalPayload);
    } catch (_) {
      throw const FormatException('Malformed STAFF mark ready payload JSON.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('STAFF mark ready payload must be a map.');
    }
    final expectedKeys = <String>{
      'serviceOrderId',
      if (decoded.containsKey('notes')) 'notes',
    };
    if (decoded.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'Unexpected keys in STAFF mark ready payload.',
      );
    }
    final serviceOrderId = decoded['serviceOrderId'];
    if (serviceOrderId is! String ||
        serviceOrderId != intent.targetId ||
        !_uuidPattern.hasMatch(serviceOrderId)) {
      throw const FormatException(
        'Invalid serviceOrderId in STAFF mark ready payload.',
      );
    }
    final rawNotes = decoded['notes'];
    if (rawNotes != null &&
        (rawNotes is! String ||
            rawNotes.trim() != rawNotes ||
            rawNotes.isEmpty ||
            rawNotes.length > 1000)) {
      throw const FormatException('Invalid notes in STAFF mark ready payload.');
    }
    return StaffSoMarkReadyIdentity(
      serviceOrderId: serviceOrderId,
      notes: rawNotes as String?,
    );
  }

  bool matchesRequestedAction({required String? requestedNotes}) =>
      notes == normalizeNotes(requestedNotes);

  @override
  Map<String, Object?> toCanonicalPayload() => {
        if (notes != null) 'notes': notes,
        'serviceOrderId': serviceOrderId,
      };
}

final class StaffSoMarkDeliveredIdentity extends StaffSoCommandIdentity {
  const StaffSoMarkDeliveredIdentity({
    required this.serviceOrderId,
    this.notes,
  });

  @override
  final String serviceOrderId;
  final String? notes;

  @override
  String get commandType => staffSoMarkDeliveredCommandType;

  factory StaffSoMarkDeliveredIdentity.fromIntent(CommandIntent intent) {
    if (intent.commandType != staffSoMarkDeliveredCommandType) {
      throw const FormatException(
        'Unexpected STAFF mark delivered command type.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(intent.canonicalPayload);
    } catch (_) {
      throw const FormatException(
        'Malformed STAFF mark delivered payload JSON.',
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'STAFF mark delivered payload must be a map.',
      );
    }
    final expectedKeys = <String>{
      'serviceOrderId',
      if (decoded.containsKey('notes')) 'notes',
    };
    if (decoded.keys.toSet().difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(decoded.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'Unexpected keys in STAFF mark delivered payload.',
      );
    }
    final serviceOrderId = decoded['serviceOrderId'];
    if (serviceOrderId is! String ||
        serviceOrderId != intent.targetId ||
        !_uuidPattern.hasMatch(serviceOrderId)) {
      throw const FormatException(
        'Invalid serviceOrderId in STAFF mark delivered payload.',
      );
    }
    final rawNotes = decoded['notes'];
    if (rawNotes != null &&
        (rawNotes is! String ||
            rawNotes.trim() != rawNotes ||
            rawNotes.isEmpty ||
            rawNotes.length > 1000)) {
      throw const FormatException(
        'Invalid notes in STAFF mark delivered payload.',
      );
    }
    return StaffSoMarkDeliveredIdentity(
      serviceOrderId: serviceOrderId,
      notes: rawNotes as String?,
    );
  }

  bool matchesRequestedAction({required String? requestedNotes}) =>
      notes == normalizeNotes(requestedNotes);

  @override
  Map<String, Object?> toCanonicalPayload() => {
        if (notes != null) 'notes': notes,
        'serviceOrderId': serviceOrderId,
      };
}

// ---------------------------------------------------------------------------
// Staff SO Command Intent Executor
// ---------------------------------------------------------------------------

final class StaffSoCommandIntentExecutor {
  const StaffSoCommandIntentExecutor({
    required this.gateway,
    required this.intentRepository,
    required this.database,
    required this.isBindingCurrent,
    required this.operationIdFactory,
  });

  final StaffSoCommandGateway gateway;
  final CommandIntentRepository intentRepository;
  final Database database;
  final bool Function() isBindingCurrent;
  final String Function() operationIdFactory;

  Future<StaffServiceOrderProjection> execute({
    required StaffSoCommandIdentity identity,
  }) {
    return CommandExecutor(
      intentRepository: intentRepository,
      database: database,
      isBindingCurrent: isBindingCurrent,
      operationIdFactory: operationIdFactory,
    ).execute(
      commandType: identity.commandType,
      targetId: identity.serviceOrderId,
      payload: identity.toCanonicalPayload(),
      dispatch: (operationId) async {
        // Phase 1: Semantic POST mutation dispatch
        switch (identity) {
          case StaffSoPublishQuoteIdentity(
              :final serviceOrderId,
              :final changeReason
            ):
            await gateway.publishInitialQuote(
              operationId: operationId,
              serviceOrderId: serviceOrderId,
              changeReason: changeReason,
            );
          case StaffSoReviseQuoteIdentity(
              :final serviceOrderId,
              :final diagnosis,
              :final items,
              :final changeReason
            ):
            await gateway.publishCommercialRevision(
              operationId: operationId,
              serviceOrderId: serviceOrderId,
              diagnosis: diagnosis,
              items: items,
              changeReason: changeReason,
            );
          case StaffSoResumeScopeIdentity(:final serviceOrderId, :final reason):
            await gateway.resumeApprovedScope(
              operationId: operationId,
              serviceOrderId: serviceOrderId,
              reason: reason,
            );
          case StaffSoMarkReadyIdentity(:final serviceOrderId, :final notes):
            await gateway.markReady(
              operationId: operationId,
              serviceOrderId: serviceOrderId,
              notes: notes,
            );
          case StaffSoMarkDeliveredIdentity(
              :final serviceOrderId,
              :final notes
            ):
            await gateway.markDelivered(
              operationId: operationId,
              serviceOrderId: serviceOrderId,
              notes: notes,
            );
        }

        // Phase 2: Binding validation after POST success
        _ensureBindingCurrent();

        // Phase 3: GET canonical projection
        final StaffServiceOrderProjection projection;
        try {
          projection = await gateway.readProjection(identity.serviceOrderId);
          if (projection.serviceOrderId != identity.serviceOrderId ||
              projection.wire['id'] != identity.serviceOrderId ||
              projection.wire['contractVersion'] != 2) {
            throw const StaffSoCommandException(
              502,
              'STAFF_PROJECTION_RESPONSE_INVALID',
            );
          }
          _ensureBindingCurrent();
        } on Object catch (error) {
          _ensureBindingCurrent();
          if (error is StateError) {
            rethrow;
          }
          throw StaffSoProjectionUncertaintyException(cause: error);
        }
        return projection;
      },
      authoritativeCommit: (executor, projection) =>
          SyncProjectionApplier.applyRecord(executor, {
        'entityType': 'SERVICE_ORDER',
        'entityId': projection.serviceOrderId,
        'data': projection.wire,
      }),
    );
  }

  void _ensureBindingCurrent() {
    if (!isBindingCurrent()) {
      throw StateError(
        'Staff SO command belongs to a stale authenticated session.',
      );
    }
  }
}
