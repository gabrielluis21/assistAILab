import 'package:sqflite/sqflite.dart';

/// Represents an explicit, session-bound credential override for a sync lease.
///
/// Distinguishes between two semantically different states:
///
/// - [BoundCredential.absent]: No credential override is supplied.
///   The caller has NOT bound a credential; ApiClient may use its normal
///   dynamic Hive-based resolution. This is appropriate for non-leased callers.
///
/// - [BoundCredential.explicit]: An explicit credential has been captured at
///   scope initiation. ApiClient MUST use exactly this value and MUST NOT fall
///   back to any dynamic credential store. A null or empty explicit credential
///   means the session had no valid token — the leased operation must fail
///   closed rather than fall through to Hive.
///
/// Never use a magic sentinel string to encode this distinction.
sealed class BoundCredential {
  const BoundCredential._();

  /// No credential override — normal ApiClient Hive-based resolution applies.
  static const BoundCredential absent = _AbsentCredential();

  /// Explicit credential captured at session initiation.
  ///
  /// [token] is the exact value to use. A null or empty [token] means the
  /// session had no valid credential; leased operations must reject HTTP
  /// execution rather than fall back to Hive.
  static BoundCredential explicit(String? token) => _ExplicitCredential(token);

  /// Returns the pinned token value if this is an [explicit] credential, or
  /// null if [absent]. Does NOT resolve from Hive.
  String? get pinnedToken => switch (this) {
        _AbsentCredential() => null,
        _ExplicitCredential(token: final t) => t,
      };

  /// True when this is an explicit credential binding (regardless of whether
  /// the captured token is null/empty).
  bool get isExplicit => this is _ExplicitCredential;

  /// True when this explicit credential has a valid (non-null, non-empty) token.
  ///
  /// Always false for [absent].
  bool get hasValidToken => switch (this) {
        _AbsentCredential() => false,
        _ExplicitCredential(token: final t) => t != null && t.trim().isNotEmpty,
      };
}

final class _AbsentCredential extends BoundCredential {
  const _AbsentCredential() : super._();
}

final class _ExplicitCredential extends BoundCredential {
  final String? token;
  const _ExplicitCredential(this.token) : super._();
}

/// A session-bound sync lease that binds a single logical sync cycle to:
/// 1. The database instance captured for the initiating scope;
/// 2. An explicit authentication credential captured for the initiating session;
/// 3. A lifecycle validity / cancellation guard.
///
/// The [credential] field uses [BoundCredential] rather than a raw [String?]
/// so that null cannot mean "fall back to Hive". A null token inside an
/// [BoundCredential.explicit] means "this session had no credential" and
/// the operation must fail closed.
class SyncLease {
  /// Database captured for the initiating scope (null on Web platform).
  final Database? db;

  /// Explicit session credential captured at scope initiation.
  ///
  /// Must be [BoundCredential.explicit]. Use [BoundCredential.absent] only for
  /// non-leased callers — it must never appear inside a [SyncLease].
  final BoundCredential credential;

  /// Lifecycle validity predicate. Returns true when the initiating coordinator
  /// or sync cycle has been cancelled, disposed, or superseded.
  final bool Function() isCancelled;

  const SyncLease({
    this.db,
    required this.credential,
    required this.isCancelled,
  });

  /// Convenience getter for positive validity check.
  bool get isStillValid => !isCancelled();

  /// The pinned auth token value. Null when credential is absent or has no token.
  /// When accessing this on a session-bound lease, always check [credential.hasValidToken]
  /// before issuing an authenticated HTTP request.
  String? get authToken => credential.pinnedToken;
}
