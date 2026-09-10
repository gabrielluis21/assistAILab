import '../entities/user.dart';

/// Non-authoritative profile cache used for UX and limited-offline proof only.
///
/// A cached [User] alone must never authenticate, create an AuthScope, open a
/// database, or start Sync.
abstract interface class UserProfileCache {
  Future<User?> read();

  Future<void> write(User user);

  Future<void> delete();
}
