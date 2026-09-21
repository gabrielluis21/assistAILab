import 'package:sqflite/sqflite.dart';

import '../../core/commands/command_executor.dart';
import '../../core/commands/command_intent.dart';
import '../../core/money/money_minor.dart';
import 'payment_command_gateway.dart';
import 'payment_entity.dart';
import 'payment_repository.dart';

enum PaymentCommandType {
  create('PAYMENT_CREATE'),
  confirm('PAYMENT_CONFIRM'),
  cancel('PAYMENT_CANCEL');

  const PaymentCommandType(this.wireValue);

  final String wireValue;

  static PaymentCommandType fromWire(Object? value) => switch (value) {
        'PAYMENT_CREATE' => PaymentCommandType.create,
        'PAYMENT_CONFIRM' => PaymentCommandType.confirm,
        'PAYMENT_CANCEL' => PaymentCommandType.cancel,
        _ => throw const FormatException('Invalid Payment command type.'),
      };
}

const paymentOwnedCommandTypes = <String>{
  'PAYMENT_CREATE',
  'PAYMENT_CONFIRM',
  'PAYMENT_CANCEL',
};

typedef PaymentCommandIntent = CommandIntent;
typedef PaymentIntentLifecycle = CommandIntentLifecycle;
typedef PaymentIntentIdentityException = CommandIntentIdentityException;
typedef PaymentCommandIntentRepository = CommandIntentRepository;
typedef PaymentCommandIntentLocalDataSource = CommandIntentLocalDataSource;

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
  final CommandIntentRepository intentRepository;
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
  }) {
    return CommandExecutor(
      intentRepository: intentRepository,
      database: database,
      isBindingCurrent: isBindingCurrent,
      operationIdFactory: operationIdFactory,
    ).execute(
      commandType: commandType.wireValue,
      targetId: targetId,
      payload: payload,
      dispatch: dispatch,
      authoritativeCommit: (executor, authoritative) =>
          paymentRepository.upsert(authoritative, executor: executor),
    );
  }
}

String canonicalPaymentCommandPayload(Map<String, Object?> payload) =>
    canonicalCommandPayload(payload);
