import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import '../../features/auth/domain/entities/auth_scope.dart';
import 'scope_hash_generator.dart';
import 'sqlite_database.dart';

class AuthScopedDatabaseManager {
  static final AuthScopedDatabaseManager instance =
      AuthScopedDatabaseManager._internal();

  AuthScopedDatabaseManager._internal();

  Database? _activeDatabase;
  AuthScope? _activeScope;
  String? _activeDbFileName;

  /// Current active [Database].
  ///
  /// Throws [StateError] if no database is active for a valid [AuthScope].
  Database get activeDatabase {
    if (kIsWeb) {
      throw UnsupportedError(
        'SQLite is not available on the Web platform. Use the API directly.',
      );
    }
    if (_activeDatabase == null || !_activeDatabase!.isOpen) {
      throw StateError(
        'No active scoped database available. An authenticated valid AuthScope must be active.',
      );
    }
    return _activeDatabase!;
  }

  /// Whether an active database connection is currently open.
  bool get hasActiveDatabase =>
      _activeDatabase != null && _activeDatabase!.isOpen;

  /// Current active [AuthScope].
  AuthScope? get activeScope => _activeScope;

  /// Name of the currently open database file.
  String? get activeDbFileName => _activeDbFileName;

  /// Opens or reuses the isolated SQLite database for the given [scope].
  ///
  /// Rejects [InvalidAuthScope] and `null` unauthenticated state (fail closed).
  /// Quarantines legacy unscoped `assistailab_local.db` (never selects it).
  Future<Database> openDatabaseForScope(AuthScope? scope) async {
    if (kIsWeb) {
      throw UnsupportedError(
        'SQLite is not available on the Web platform. Use the API directly.',
      );
    }

    if (scope == null) {
      await closeCurrentDatabase();
      throw StateError(
        'Cannot open database for unauthenticated null AuthScope (fail closed).',
      );
    }

    if (scope is InvalidAuthScope) {
      await closeCurrentDatabase();
      throw StateError(
        'Cannot open database for InvalidAuthScope: ${scope.reason} (fail closed).',
      );
    }

    final dbFileName = ScopeHashGenerator.databaseFileName(scope);

    // Legacy database quarantine check
    if (dbFileName == 'assistailab_local.db') {
      throw StateError(
        'Legacy assistailab_local.db is quarantined and cannot be opened as a scoped database.',
      );
    }

    // Reuse existing connection if same scope and file
    if (_activeDatabase != null &&
        _activeDatabase!.isOpen &&
        _activeDbFileName == dbFileName &&
        _activeScope == scope) {
      return _activeDatabase!;
    }

    // Close any previous open database before opening a new scope database
    await closeCurrentDatabase();

    final db = await SqliteDatabase.openDatabaseByName(dbFileName);
    _activeDatabase = db;
    _activeScope = scope;
    _activeDbFileName = dbFileName;

    return db;
  }

  /// Closes the active database connection and resets scope state.
  Future<void> closeCurrentDatabase() async {
    if (_activeDatabase != null) {
      if (_activeDatabase!.isOpen) {
        await _activeDatabase!.close();
      }
      _activeDatabase = null;
      _activeScope = null;
      _activeDbFileName = null;
    }
  }
}
