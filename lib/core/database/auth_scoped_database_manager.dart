import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:sqflite/sqflite.dart';

import '../../features/auth/domain/entities/auth_scope.dart';
import 'scope_hash_generator.dart';
import 'sqlite_database.dart';

typedef ScopedDatabaseOpener = Future<Database> Function(String fileName);
typedef ScopedDatabaseCloser = Future<void> Function(Database database);

/// Immutable proof that a database belongs to one authenticated session.
final class BoundDatabaseHandle {
  final AuthScope authScope;
  final int sessionGeneration;
  final int lifecycleEpoch;
  final Database database;
  final String fileName;

  const BoundDatabaseHandle({
    required this.authScope,
    required this.sessionGeneration,
    required this.lifecycleEpoch,
    required this.database,
    required this.fileName,
  });
}

class AuthScopedDatabaseManager {
  static final AuthScopedDatabaseManager instance =
      AuthScopedDatabaseManager._internal();

  final ScopedDatabaseOpener _opener;
  final ScopedDatabaseCloser _closer;

  BoundDatabaseHandle? _publishedHandle;
  int _acceptedSessionGeneration = -1;
  int _lifecycleEpoch = 0;

  Future<void> _commitTail = Future<void>.value();
  final Map<String, Future<void>> _fileTails = <String, Future<void>>{};

  AuthScopedDatabaseManager._internal()
      : _opener = SqliteDatabase.openDatabaseByName,
        _closer = _defaultCloser;

  /// Creates an isolated manager with controllable I/O for deterministic races.
  @visibleForTesting
  AuthScopedDatabaseManager.forTesting({
    required ScopedDatabaseOpener opener,
    ScopedDatabaseCloser closer = _defaultCloser,
  })  : _opener = opener,
        _closer = closer;

  static Future<void> _defaultCloser(Database database) async {
    if (database.isOpen) {
      await database.close();
    }
  }

  /// The only currently valid session/database binding, or `null`.
  BoundDatabaseHandle? get currentHandle {
    final handle = _publishedHandle;
    return handle != null && isCurrentHandle(handle) ? handle : null;
  }

  /// Alias retained for orchestration code that names the active binding.
  BoundDatabaseHandle? get activeHandle => currentHandle;

  /// Whether [handle] is still the unique binding published by this manager.
  bool isCurrentHandle(BoundDatabaseHandle handle) {
    final published = _publishedHandle;
    return identical(published, handle) &&
        handle.lifecycleEpoch == _lifecycleEpoch &&
        handle.sessionGeneration == _acceptedSessionGeneration &&
        handle.database.isOpen;
  }

  /// Current active [Database].
  ///
  /// Throws [StateError] if no current database is bound to a session.
  Database get activeDatabase {
    if (kIsWeb) {
      throw UnsupportedError(
        'SQLite is not available on the Web platform. Use the API directly.',
      );
    }
    final handle = currentHandle;
    if (handle == null) {
      throw StateError(
        'No active scoped database available. An authenticated valid AuthScope must be active.',
      );
    }
    return handle.database;
  }

  /// Whether a current database connection is open.
  bool get hasActiveDatabase => currentHandle != null;

  /// Current active [AuthScope].
  AuthScope? get activeScope => currentHandle?.authScope;

  /// Name of the currently open database file.
  String? get activeDbFileName => currentHandle?.fileName;

  /// Opens or reuses the isolated SQLite database for [scope].
  ///
  /// Every accepted call invalidates the prior lifecycle epoch synchronously.
  /// Calls from a generation older than the greatest accepted generation are
  /// rejected without affecting the current binding.
  Future<BoundDatabaseHandle> openDatabaseForScope(
    AuthScope? scope, {
    required int sessionGeneration,
  }) {
    if (kIsWeb) {
      return Future<BoundDatabaseHandle>.error(
        UnsupportedError(
          'SQLite is not available on the Web platform. Use the API directly.',
        ),
      );
    }

    if (!_acceptGeneration(sessionGeneration)) {
      return Future<BoundDatabaseHandle>.error(
        StateError(
          'Stale database open ignored for session generation '
          '$sessionGeneration; accepted generation is '
          '$_acceptedSessionGeneration.',
        ),
      );
    }

    final requestEpoch = ++_lifecycleEpoch;

    if (scope == null) {
      return _rejectScopeAndClose(
        sessionGeneration: sessionGeneration,
        requestEpoch: requestEpoch,
        error: StateError(
          'Cannot open database for unauthenticated null AuthScope (fail closed).',
        ),
      );
    }

    if (scope is InvalidAuthScope) {
      return _rejectScopeAndClose(
        sessionGeneration: sessionGeneration,
        requestEpoch: requestEpoch,
        error: StateError(
          'Cannot open database for InvalidAuthScope: ${scope.reason} (fail closed).',
        ),
      );
    }

    final fileName = ScopeHashGenerator.databaseFileName(scope);
    if (fileName == 'assistailab_local.db') {
      return _rejectScopeAndClose(
        sessionGeneration: sessionGeneration,
        requestEpoch: requestEpoch,
        error: StateError(
          'Legacy assistailab_local.db is quarantined and cannot be opened as a scoped database.',
        ),
      );
    }

    // The file lane spans preparation, physical open, commit and stale cleanup.
    // Different files can open concurrently; the same file cannot yield shared
    // sqflite handles that one stale request could close under another request.
    return _runInFileLane(
      fileName,
      () => _performOpen(
        scope: scope,
        fileName: fileName,
        sessionGeneration: sessionGeneration,
        requestEpoch: requestEpoch,
      ),
    );
  }

  /// Closes the current binding for [sessionGeneration].
  ///
  /// The epoch and published handle are invalidated synchronously. A close from
  /// an older generation is a no-op and cannot close a newer session database.
  Future<void> closeCurrentDatabase({
    required int sessionGeneration,
  }) {
    if (kIsWeb) {
      return Future<void>.value();
    }
    if (!_acceptGeneration(sessionGeneration)) {
      return Future<void>.value();
    }

    final closeEpoch = ++_lifecycleEpoch;
    final detached = _publishedHandle;
    _publishedHandle = null;

    // Reserve the database file lane before yielding. A same-file open invoked
    // immediately after logout must wait until this physical close completes.
    final closeFuture = detached == null
        ? Future<void>.value()
        : _runInFileLane(
            detached.fileName,
            () => _closeUnlessPublished(detached.database),
          );

    return _runInCommitLane(() async {
      final wasCurrentBeforeClose = closeEpoch == _lifecycleEpoch;
      await closeFuture;
      if (!wasCurrentBeforeClose || closeEpoch != _lifecycleEpoch) {
        return;
      }
      // No state is published after this await. A newer epoch, if any, owns all
      // subsequent state and cannot be cleared by this close.
    });
  }

  bool _acceptGeneration(int sessionGeneration) {
    if (sessionGeneration < _acceptedSessionGeneration) {
      return false;
    }
    _acceptedSessionGeneration = sessionGeneration;
    return true;
  }

  bool _isRequestCurrent(int sessionGeneration, int requestEpoch) =>
      sessionGeneration == _acceptedSessionGeneration &&
      requestEpoch == _lifecycleEpoch;

  Future<BoundDatabaseHandle> _rejectScopeAndClose({
    required int sessionGeneration,
    required int requestEpoch,
    required Object error,
  }) async {
    final detached = _publishedHandle;
    _publishedHandle = null;
    final closeFuture = detached == null
        ? Future<void>.value()
        : _runInFileLane(
            detached.fileName,
            () => _closeUnlessPublished(detached.database),
          );

    await _runInCommitLane(() async {
      final wasCurrentBeforeClose =
          _isRequestCurrent(sessionGeneration, requestEpoch);
      await closeFuture;
      if (!wasCurrentBeforeClose ||
          !_isRequestCurrent(sessionGeneration, requestEpoch)) {
        return;
      }
    });
    throw error;
  }

  Future<BoundDatabaseHandle> _performOpen({
    required AuthScope scope,
    required String fileName,
    required int sessionGeneration,
    required int requestEpoch,
  }) async {
    _throwIfStale(sessionGeneration, requestEpoch);

    final reused = await _runInCommitLane<BoundDatabaseHandle?>(() async {
      _throwIfStale(sessionGeneration, requestEpoch);
      final existing = _publishedHandle;
      if (existing == null || existing.fileName != fileName) {
        return null;
      }

      if (existing.authScope == scope &&
          existing.sessionGeneration == sessionGeneration &&
          existing.database.isOpen) {
        final rebound = BoundDatabaseHandle(
          authScope: scope,
          sessionGeneration: sessionGeneration,
          lifecycleEpoch: requestEpoch,
          database: existing.database,
          fileName: fileName,
        );
        _publishedHandle = rebound;
        return rebound;
      }

      // This operation owns the file lane, so it can safely close an older
      // same-file connection directly before opening a replacement.
      _publishedHandle = null;
      await _closeUnlessPublished(existing.database);
      _throwIfStale(sessionGeneration, requestEpoch);
      return null;
    });
    if (reused != null) {
      _throwIfStale(sessionGeneration, requestEpoch);
      return reused;
    }

    _throwIfStale(sessionGeneration, requestEpoch);
    final openedDatabase = await _opener(fileName);
    if (!_isRequestCurrent(sessionGeneration, requestEpoch)) {
      await _closeUnlessPublished(openedDatabase);
      _throwIfStale(sessionGeneration, requestEpoch);
    }

    BoundDatabaseHandle? committedHandle;
    try {
      committedHandle = await _runInCommitLane<BoundDatabaseHandle?>(() async {
        if (!_isRequestCurrent(sessionGeneration, requestEpoch)) {
          return null;
        }

        final previous = _publishedHandle;
        _publishedHandle = null;

        if (previous != null && !identical(previous.database, openedDatabase)) {
          // Reserve the previous file before yielding so a newer open of that
          // file cannot race its physical close.
          final closePrevious = _runInFileLane(
            previous.fileName,
            () => _closeUnlessPublished(previous.database),
          );
          await closePrevious;
        }

        if (!_isRequestCurrent(sessionGeneration, requestEpoch)) {
          return null;
        }

        final handle = BoundDatabaseHandle(
          authScope: scope,
          sessionGeneration: sessionGeneration,
          lifecycleEpoch: requestEpoch,
          database: openedDatabase,
          fileName: fileName,
        );
        _publishedHandle = handle;
        return handle;
      });
    } catch (_) {
      await _closeUnlessPublished(openedDatabase);
      rethrow;
    }

    if (committedHandle == null) {
      await _closeUnlessPublished(openedDatabase);
      throw StateError(
        'Scoped database lifecycle was superseded before commit '
        '(session generation $sessionGeneration, epoch $requestEpoch).',
      );
    }
    if (!_isRequestCurrent(sessionGeneration, requestEpoch)) {
      await _closeUnlessPublished(openedDatabase);
      _throwIfStale(sessionGeneration, requestEpoch);
    }

    return committedHandle;
  }

  void _throwIfStale(int sessionGeneration, int requestEpoch) {
    if (!_isRequestCurrent(sessionGeneration, requestEpoch)) {
      throw StateError(
        'Scoped database lifecycle was superseded before commit '
        '(session generation $sessionGeneration, epoch $requestEpoch).',
      );
    }
  }

  Future<void> _closeUnlessPublished(Database database) async {
    if (identical(_publishedHandle?.database, database)) {
      return;
    }
    if (database.isOpen) {
      await _closer(database);
    }
  }

  Future<T> _runInCommitLane<T>(Future<T> Function() action) {
    final predecessor = _commitTail;
    final release = Completer<void>();
    _commitTail = release.future;

    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        release.complete();
      }
    }();
  }

  Future<T> _runInFileLane<T>(
    String fileName,
    Future<T> Function() action,
  ) {
    final predecessor = _fileTails[fileName] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = release.future;
    _fileTails[fileName] = tail;

    return () async {
      await predecessor;
      try {
        return await action();
      } finally {
        release.complete();
        if (identical(_fileTails[fileName], tail)) {
          _fileTails.remove(fileName);
        }
      }
    }();
  }
}
