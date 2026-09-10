// sync_race_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/core/sync/sync_engine.dart';
import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

void main() {
  test('sync race condition with detailed logs', () async {
    // Ensure DB is initialized (web guard handled inside SqliteDatabase).
    final db = await SqliteDatabase.instance;
    // Create a sync engine with a dummy executor that simulates delay.
    final engine = SyncEngine(executor: db);
    // Start two syncs concurrently.
    final sync1 = engine.performSync();
    final sync2 = engine.performSync();
    // Await both.
    await Future.wait([sync1, sync2]);
    if (kDebugMode) {
      // Detailed debug log for the test run.
      print('Sync race test completed.');
    }
  });
}
