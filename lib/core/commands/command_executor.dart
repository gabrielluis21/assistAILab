import 'package:sqflite/sqflite.dart';

import 'command_failure.dart';
import 'command_intent.dart';

final class CommandExecutor {
  const CommandExecutor({
    required this.intentRepository,
    required this.database,
    required this.isBindingCurrent,
    required this.operationIdFactory,
  });

  final CommandIntentRepository intentRepository;
  final Database database;
  final bool Function() isBindingCurrent;
  final String Function() operationIdFactory;

  Future<Result> execute<Result>({
    required String commandType,
    required String targetId,
    required Map<String, Object?> payload,
    required Future<Result> Function(String operationId) dispatch,
    required Future<void> Function(
      DatabaseExecutor executor,
      Result authoritative,
    ) authoritativeCommit,
  }) async {
    _ensureCurrent();
    final intent = await database.transaction((txn) async {
      _ensureCurrent();
      return intentRepository.getOrCreate(
        commandType: commandType,
        targetId: targetId,
        payload: payload,
        operationIdFactory: operationIdFactory,
        executor: txn,
      );
    });
    _ensureCurrent();
    await intentRepository.setLifecycle(
      intent.operationId,
      CommandIntentLifecycle.sending,
      executor: database,
    );
    _ensureCurrent();

    try {
      final authoritative = await dispatch(intent.operationId);
      _ensureCurrent();
      await database.transaction((txn) async {
        _ensureCurrent();
        await authoritativeCommit(txn, authoritative);
        _ensureCurrent();
        await intentRepository.setLifecycle(
          intent.operationId,
          CommandIntentLifecycle.completed,
          executor: txn,
        );
      });
      _ensureCurrent();
      return authoritative;
    } catch (error) {
      if (!isBindingCurrent()) rethrow;
      final lifecycle = switch (classifyCommandFailure(error)) {
        CommandFailureDisposition.unknown => CommandIntentLifecycle.unknown,
        CommandFailureDisposition.rejected => CommandIntentLifecycle.rejected,
      };
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
      throw StateError('Command belongs to a stale authenticated session.');
    }
  }
}
