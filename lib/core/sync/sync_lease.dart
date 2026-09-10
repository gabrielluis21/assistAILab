import 'package:sqflite/sqflite.dart';

/// A session-bound sync lease that binds a single logical sync cycle to:
/// 1. The database instance captured for the initiating scope;
/// 2. The authentication credential captured for the initiating session;
/// 3. A lifecycle validity / cancellation guard.
class SyncLease {
  /// Database captured for the initiating scope (null on Web platform).
  final Database? db;

  /// Authentication token captured for the initiating session.
  final String? authToken;

  /// Lifecycle validity predicate. Returns true when the initiating coordinator
  /// or sync cycle has been cancelled, disposed, or superseded.
  final bool Function() isCancelled;

  const SyncLease({
    this.db,
    this.authToken,
    required this.isCancelled,
  });

  /// Convenience getter for positive validity check.
  bool get isStillValid => !isCancelled();
}
