import 'dart:async';

class CommandException implements Exception {
  const CommandException(this.statusCode, this.errorCode);

  final int statusCode;
  final String errorCode;

  String get message => errorCode;

  @override
  String toString() => 'CommandException($statusCode): $errorCode';
}

enum CommandFailureDisposition { unknown, rejected }

CommandFailureDisposition classifyCommandFailure(Object error) {
  if (error is CommandException) {
    if (error.statusCode == 408 || error.statusCode == 429) {
      return CommandFailureDisposition.unknown;
    }
    if (error.statusCode == 409 &&
        const {
          'IDEMPOTENCY_IN_PROGRESS',
          'IDEMPOTENCY_STATE_CONFLICT',
        }.contains(error.errorCode)) {
      return CommandFailureDisposition.unknown;
    }
    if (error.statusCode >= 400 && error.statusCode < 500) {
      return CommandFailureDisposition.rejected;
    }
    if (error.statusCode >= 500) return CommandFailureDisposition.unknown;
  }
  if (error is TimeoutException) return CommandFailureDisposition.unknown;
  return CommandFailureDisposition.unknown;
}
