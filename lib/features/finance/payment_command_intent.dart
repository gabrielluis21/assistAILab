import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../../core/money/money_minor.dart';
import 'payment_command_gateway.dart';
import 'payment_entity.dart';
import 'payment_repository.dart';

enum PaymentCommandType {
  create,
  confirm,
  cancel;

  String get wireValue => name.toUpperCase();

  static PaymentCommandType fromWire(Object? value) => switch (value) {
        'CREATE' => PaymentCommandType.create,
        'CONFIRM' => PaymentCommandType.confirm,
        'CANCEL' => PaymentCommandType.cancel,
        _ => throw const FormatException('Invalid Payment command type.'),
      };
}

enum PaymentIntentLifecycle {
  pending,
  sending,
  unknown,
  completed,
  rejected;

  String get wireValue => name.toUpperCase();

  bool get isUnresolved =>
      this == pending || this == sending || this == unknown;

  static PaymentIntentLifecycle fromWire(Object? value) => switch (value) {
        'PENDING' => PaymentIntentLifecycle.pending,
        'SENDING' => PaymentIntentLifecycle.sending,
        'UNKNOWN' => PaymentIntentLifecycle.unknown,
        'COMPLETED' => PaymentIntentLifecycle.completed,
        'REJECTED' => PaymentIntentLifecycle.rejected,
        _ => throw const FormatException('Invalid Payment intent lifecycle.'),
      };
}

final class PaymentIntentIdentityException implements Exception {
  const PaymentIntentIdentityException(this.message);

  final String message;

  @override
  String toString() => 'PaymentIntentIdentityException: $message';
}

final class PaymentCommandIntent {
  const PaymentCommandIntent({
    required this.operationId,
    required this.commandType,
    required this.targetId,
    required this.canonicalPayload,
    required this.lifecycle,
    required this.createdAt,
    required this.updatedAt,
  });

  final String operationId;
  final PaymentCommandType commandType;
  final String targetId;
  final String canonicalPayload;
  final PaymentIntentLifecycle lifecycle;
  final String createdAt;
  final String updatedAt;

  factory PaymentCommandIntent.fromMap(Map<String, Object?> map) {
    final operationId = map['operation_id'];
    final targetId = map['target_id'];
    final payload = map['payload_json'];
    final createdAt = map['created_at'];
    final updatedAt = map['updated_at'];
    if (operationId is! String ||
        operationId.isEmpty ||
        targetId is! String ||
        targetId.isEmpty ||
        payload is! String ||
        payload.isEmpty ||
        createdAt is! String ||
        createdAt.isEmpty ||
        updatedAt is! String ||
        updatedAt.isEmpty) {
      throw const FormatException('Malformed Payment command intent.');
    }
    return PaymentCommandIntent(
      operationId: operationId,
      commandType: PaymentCommandType.fromWire(map['command_type']),
      targetId: targetId,
      canonicalPayload: payload,
      lifecycle: PaymentIntentLifecycle.fromWire(map['lifecycle_state']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

abstract interface class PaymentCommandIntentRepository {
  Future<PaymentCommandIntent> getOrCreate({
    required PaymentCommandType commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required String Function() operationIdFactory,
    required DatabaseExecutor executor,
  });

  Future<void> setLifecycle(
    String operationId,
    PaymentIntentLifecycle lifecycle, {
    required DatabaseExecutor executor,
  });

  Future<void> recoverInterruptedSending({
    required DatabaseExecutor executor,
  });
}

final class PaymentCommandIntentLocalDataSource
    implements PaymentCommandIntentRepository {
  PaymentCommandIntentLocalDataSource({DateTime Function()? nowUtc})
      : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final DateTime Function() _nowUtc;

  @override
  Future<PaymentCommandIntent> getOrCreate({
    required PaymentCommandType commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required String Function() operationIdFactory,
    required DatabaseExecutor executor,
  }) async {
    if (targetId.isEmpty) {
      throw ArgumentError.value(targetId, 'targetId', 'Must not be empty.');
    }
    final canonicalPayload = canonicalPaymentCommandPayload(payload);
    final reusable = await executor.query(
      'payment_command_intents',
      where: 'command_type = ? AND target_id = ? AND payload_json = ? '
          "AND lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')",
      whereArgs: [commandType.wireValue, targetId, canonicalPayload],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (reusable.isNotEmpty) {
      return PaymentCommandIntent.fromMap(reusable.single);
    }

    final operationId = operationIdFactory();
    if (operationId.isEmpty) {
      throw const PaymentIntentIdentityException(
        'Generated operationId must not be empty.',
      );
    }
    final collision = await executor.query(
      'payment_command_intents',
      where: 'operation_id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    if (collision.isNotEmpty) {
      final existing = PaymentCommandIntent.fromMap(collision.single);
      final sameIdentity = existing.commandType == commandType &&
          existing.targetId == targetId &&
          existing.canonicalPayload == canonicalPayload;
      throw PaymentIntentIdentityException(
        sameIdentity
            ? 'operationId was already used by a resolved Payment intent.'
            : 'operationId cannot be reused with another Payment payload.',
      );
    }

    final now = _nowUtc().toIso8601String();
    await executor.insert('payment_command_intents', {
      'operation_id': operationId,
      'command_type': commandType.wireValue,
      'target_id': targetId,
      'payload_json': canonicalPayload,
      'lifecycle_state': PaymentIntentLifecycle.pending.wireValue,
      'created_at': now,
      'updated_at': now,
    });
    return PaymentCommandIntent(
      operationId: operationId,
      commandType: commandType,
      targetId: targetId,
      canonicalPayload: canonicalPayload,
      lifecycle: PaymentIntentLifecycle.pending,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> setLifecycle(
    String operationId,
    PaymentIntentLifecycle lifecycle, {
    required DatabaseExecutor executor,
  }) async {
    final rows = await executor.query(
      'payment_command_intents',
      where: 'operation_id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Payment command intent does not exist.');
    }
    final current = PaymentCommandIntent.fromMap(rows.single).lifecycle;
    if (!_isAllowedTransition(current, lifecycle)) {
      throw StateError(
        'Invalid Payment intent transition: '
        '${current.wireValue} -> ${lifecycle.wireValue}.',
      );
    }
    await executor.update(
      'payment_command_intents',
      {
        'lifecycle_state': lifecycle.wireValue,
        'updated_at': _nowUtc().toIso8601String(),
      },
      where: 'operation_id = ?',
      whereArgs: [operationId],
    );
  }

  @override
  Future<void> recoverInterruptedSending({
    required DatabaseExecutor executor,
  }) async {
    await executor.update(
      'payment_command_intents',
      {
        'lifecycle_state': PaymentIntentLifecycle.unknown.wireValue,
        'updated_at': _nowUtc().toIso8601String(),
      },
      where: 'lifecycle_state = ?',
      whereArgs: [PaymentIntentLifecycle.sending.wireValue],
    );
  }

  static bool _isAllowedTransition(
    PaymentIntentLifecycle current,
    PaymentIntentLifecycle next,
  ) {
    if (current == next && next == PaymentIntentLifecycle.sending) return true;
    return switch (current) {
      PaymentIntentLifecycle.pending => next == PaymentIntentLifecycle.sending,
      PaymentIntentLifecycle.sending =>
        next == PaymentIntentLifecycle.unknown ||
            next == PaymentIntentLifecycle.completed ||
            next == PaymentIntentLifecycle.rejected,
      PaymentIntentLifecycle.unknown => next == PaymentIntentLifecycle.sending,
      PaymentIntentLifecycle.completed ||
      PaymentIntentLifecycle.rejected =>
        false,
    };
  }
}

final class PaymentCommandIntentExecutor {
  const PaymentCommandIntentExecutor({
    required this.gateway,
    required this.paymentRepository,
    required this.intentRepository,
    required this.database,
    required this.isBindingCurrent,
    required this.operationIdFactory,
  });

  final PaymentCommandGateway gateway;
  final PaymentRepository paymentRepository;
  final PaymentCommandIntentRepository intentRepository;
  final Database database;
  final bool Function() isBindingCurrent;
  final String Function() operationIdFactory;

  Future<PaymentEntity> create({
    required String serviceOrderId,
    required MoneyMinor amount,
    required PaymentMethod method,
    String? notes,
  }) {
    final normalizedNotes = notes?.trim();
    final payload = <String, Object?>{
      'amountMinor': amount.minorUnits,
      'method': method.toDbString(),
      if (normalizedNotes != null && normalizedNotes.isNotEmpty)
        'notes': normalizedNotes,
      'serviceOrderId': serviceOrderId,
    };
    return _execute(
      commandType: PaymentCommandType.create,
      targetId: serviceOrderId,
      payload: payload,
      dispatch: (operationId) => gateway.create(
        operationId: operationId,
        serviceOrderId: serviceOrderId,
        amount: amount,
        method: method,
        notes: normalizedNotes,
      ),
    );
  }

  Future<PaymentEntity> transition({
    required String paymentId,
    required PaymentStatus status,
  }) {
    final commandType = switch (status) {
      PaymentStatus.confirmed => PaymentCommandType.confirm,
      PaymentStatus.cancelled => PaymentCommandType.cancel,
      _ =>
        throw ArgumentError.value(status, 'status', 'Unsupported transition'),
    };
    return _execute(
      commandType: commandType,
      targetId: paymentId,
      payload: {
        'paymentId': paymentId,
        'status': status.toDbString(),
      },
      dispatch: (operationId) => gateway.transition(
        operationId: operationId,
        paymentId: paymentId,
        status: status,
      ),
    );
  }

  Future<PaymentEntity> _execute({
    required PaymentCommandType commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required Future<PaymentEntity> Function(String operationId) dispatch,
  }) async {
    _ensureCurrent();
    final intent = await database.transaction(
      (txn) => intentRepository.getOrCreate(
        commandType: commandType,
        targetId: targetId,
        payload: payload,
        operationIdFactory: operationIdFactory,
        executor: txn,
      ),
    );
    _ensureCurrent();
    await intentRepository.setLifecycle(
      intent.operationId,
      PaymentIntentLifecycle.sending,
      executor: database,
    );
    _ensureCurrent();

    try {
      final authoritative = await dispatch(intent.operationId);
      _ensureCurrent();
      await database.transaction((txn) async {
        _ensureCurrent();
        await paymentRepository.upsert(authoritative, executor: txn);
        _ensureCurrent();
        await intentRepository.setLifecycle(
          intent.operationId,
          PaymentIntentLifecycle.completed,
          executor: txn,
        );
      });
      _ensureCurrent();
      return authoritative;
    } catch (error) {
      if (!isBindingCurrent()) rethrow;
      final lifecycle = _failureLifecycle(error);
      _ensureCurrent();
      await intentRepository.setLifecycle(
        intent.operationId,
        lifecycle,
        executor: database,
      );
      rethrow;
    }
  }

  void _ensureCurrent() {
    if (!isBindingCurrent()) {
      throw StateError('Payment command belongs to a stale session.');
    }
  }

  static PaymentIntentLifecycle _failureLifecycle(Object error) {
    if (error is PaymentCommandException &&
        error.statusCode >= 400 &&
        error.statusCode < 500 &&
        error.statusCode != 408 &&
        error.statusCode != 429) {
      return PaymentIntentLifecycle.rejected;
    }
    return PaymentIntentLifecycle.unknown;
  }
}

String canonicalPaymentCommandPayload(Map<String, Object?> payload) =>
    jsonEncode(_canonicalize(payload));

Object? _canonicalize(Object? value) {
  if (value is List) {
    return value.map(_canonicalize).toList(growable: false);
  }
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value == null || value is String || value is int || value is bool) {
    return value;
  }
  throw const FormatException('Payment command payload is not canonical.');
}
