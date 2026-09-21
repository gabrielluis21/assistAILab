import 'dart:convert';

import 'package:sqflite/sqflite.dart';

enum CommandIntentLifecycle {
  pending,
  sending,
  unknown,
  completed,
  rejected;

  String get wireValue => name.toUpperCase();

  bool get isUnresolved =>
      this == pending || this == sending || this == unknown;

  static CommandIntentLifecycle fromWire(Object? value) => switch (value) {
        'PENDING' => CommandIntentLifecycle.pending,
        'SENDING' => CommandIntentLifecycle.sending,
        'UNKNOWN' => CommandIntentLifecycle.unknown,
        'COMPLETED' => CommandIntentLifecycle.completed,
        'REJECTED' => CommandIntentLifecycle.rejected,
        _ => throw const FormatException('Invalid command intent lifecycle.'),
      };
}

final class CommandIntentIdentityException implements Exception {
  const CommandIntentIdentityException(this.message);

  final String message;

  @override
  String toString() => 'CommandIntentIdentityException: $message';
}

final class CommandIntent {
  const CommandIntent({
    required this.operationId,
    required this.commandType,
    required this.targetId,
    required this.canonicalPayload,
    required this.lifecycle,
    required this.createdAt,
    required this.updatedAt,
  });

  final String operationId;
  final String commandType;
  final String targetId;
  final String canonicalPayload;
  final CommandIntentLifecycle lifecycle;
  final String createdAt;
  final String updatedAt;

  factory CommandIntent.fromMap(Map<String, Object?> map) {
    final operationId = map['operation_id'];
    final commandType = map['command_type'];
    final targetId = map['target_id'];
    final payload = map['payload_json'];
    final createdAt = map['created_at'];
    final updatedAt = map['updated_at'];
    if (operationId is! String ||
        operationId.isEmpty ||
        commandType is! String ||
        targetId is! String ||
        targetId.isEmpty ||
        payload is! String ||
        createdAt is! String ||
        DateTime.tryParse(createdAt) == null ||
        updatedAt is! String ||
        DateTime.tryParse(updatedAt) == null) {
      throw const FormatException('Malformed command intent.');
    }
    validateCommandType(commandType);
    validateCanonicalCommandPayload(payload);
    return CommandIntent(
      operationId: operationId,
      commandType: commandType,
      targetId: targetId,
      canonicalPayload: payload,
      lifecycle: CommandIntentLifecycle.fromWire(map['lifecycle_state']),
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

abstract interface class CommandIntentRepository {
  Future<CommandIntent> getOrCreate({
    required String commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required String Function() operationIdFactory,
    required DatabaseExecutor executor,
  });

  Future<void> setLifecycle(
    String operationId,
    CommandIntentLifecycle lifecycle, {
    required DatabaseExecutor executor,
  });

  Future<void> recoverInterruptedSending({
    required Set<String> ownedCommandTypes,
    required DatabaseExecutor executor,
  });
}

final class CommandIntentLocalDataSource implements CommandIntentRepository {
  CommandIntentLocalDataSource({DateTime Function()? nowUtc})
      : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final DateTime Function() _nowUtc;

  @override
  Future<CommandIntent> getOrCreate({
    required String commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required String Function() operationIdFactory,
    required DatabaseExecutor executor,
  }) async {
    validateCommandType(commandType);
    if (targetId.isEmpty) {
      throw ArgumentError.value(targetId, 'targetId', 'Must not be empty.');
    }
    final canonicalPayload = canonicalCommandPayload(payload);
    final reusable = await executor.query(
      'command_intents',
      where: 'command_type = ? AND target_id = ? AND payload_json = ? '
          "AND lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')",
      whereArgs: [commandType, targetId, canonicalPayload],
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (reusable.isNotEmpty) return CommandIntent.fromMap(reusable.single);

    final operationId = operationIdFactory();
    if (operationId.isEmpty) {
      throw const CommandIntentIdentityException(
        'Generated operationId must not be empty.',
      );
    }
    final collision = await executor.query(
      'command_intents',
      where: 'operation_id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    if (collision.isNotEmpty) {
      final existing = CommandIntent.fromMap(collision.single);
      final sameIdentity = existing.commandType == commandType &&
          existing.targetId == targetId &&
          existing.canonicalPayload == canonicalPayload;
      throw CommandIntentIdentityException(
        sameIdentity
            ? 'operationId was already used by a resolved command intent.'
            : 'operationId cannot be reused with another command identity.',
      );
    }

    final now = _nowUtc().toIso8601String();
    await executor.insert('command_intents', {
      'operation_id': operationId,
      'command_type': commandType,
      'target_id': targetId,
      'payload_json': canonicalPayload,
      'lifecycle_state': CommandIntentLifecycle.pending.wireValue,
      'created_at': now,
      'updated_at': now,
    });
    return CommandIntent(
      operationId: operationId,
      commandType: commandType,
      targetId: targetId,
      canonicalPayload: canonicalPayload,
      lifecycle: CommandIntentLifecycle.pending,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> setLifecycle(
    String operationId,
    CommandIntentLifecycle lifecycle, {
    required DatabaseExecutor executor,
  }) async {
    final rows = await executor.query(
      'command_intents',
      where: 'operation_id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Command intent does not exist.');
    final current = CommandIntent.fromMap(rows.single).lifecycle;
    if (!_isAllowedTransition(current, lifecycle)) {
      throw StateError(
        'Invalid command intent transition: '
        '${current.wireValue} -> ${lifecycle.wireValue}.',
      );
    }
    await executor.update(
      'command_intents',
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
    required Set<String> ownedCommandTypes,
    required DatabaseExecutor executor,
  }) async {
    if (ownedCommandTypes.isEmpty) {
      throw ArgumentError.value(
        ownedCommandTypes,
        'ownedCommandTypes',
        'Recovery ownership must not be empty.',
      );
    }
    final commandTypes = ownedCommandTypes.toSet().toList()..sort();
    for (final commandType in commandTypes) {
      validateCommandType(commandType);
    }
    final placeholders = List.filled(commandTypes.length, '?').join(', ');
    await executor.update(
      'command_intents',
      {
        'lifecycle_state': CommandIntentLifecycle.unknown.wireValue,
        'updated_at': _nowUtc().toIso8601String(),
      },
      where: 'lifecycle_state = ? AND command_type IN ($placeholders)',
      whereArgs: [
        CommandIntentLifecycle.sending.wireValue,
        ...commandTypes,
      ],
    );
  }

  static bool _isAllowedTransition(
    CommandIntentLifecycle current,
    CommandIntentLifecycle next,
  ) {
    if (current == next && next == CommandIntentLifecycle.sending) return true;
    return switch (current) {
      CommandIntentLifecycle.pending => next == CommandIntentLifecycle.sending,
      CommandIntentLifecycle.sending =>
        next == CommandIntentLifecycle.unknown ||
            next == CommandIntentLifecycle.completed ||
            next == CommandIntentLifecycle.rejected,
      CommandIntentLifecycle.unknown => next == CommandIntentLifecycle.sending,
      CommandIntentLifecycle.completed ||
      CommandIntentLifecycle.rejected =>
        false,
    };
  }
}

void validateCommandType(String commandType) {
  if (!RegExp(r'^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+$').hasMatch(commandType)) {
    throw const FormatException(
      'Command type must be a globally namespaced uppercase identifier.',
    );
  }
}

String canonicalCommandPayload(Map<String, Object?> payload) =>
    jsonEncode(_canonicalize(payload));

void validateCanonicalCommandPayload(String payload) {
  Object? decoded;
  try {
    decoded = jsonDecode(payload);
  } catch (_) {
    throw const FormatException('Command payload is not valid JSON.');
  }
  if (decoded is! Map<String, dynamic> ||
      canonicalCommandPayload(decoded) != payload) {
    throw const FormatException('Command payload is not canonical.');
  }
}

Object? _canonicalize(Object? value) {
  if (value is List) {
    return value.map(_canonicalize).toList(growable: false);
  }
  if (value is Map) {
    if (value.keys.any((key) => key is! String)) {
      throw const FormatException('Command payload keys must be strings.');
    }
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value == null || value is String || value is int || value is bool) {
    return value;
  }
  throw const FormatException('Command payload is not canonical.');
}
