import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_module.dart';
import 'app_widget.dart';
import 'core/database/hive_storage.dart';
import 'core/sync/sync_providers.dart';
import 'local_service/local_service_runner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(
    fileName: '.env',
  );

  // Initialize Hive Storage (Preferences ONLY)
  await HiveStorage.init();

  // Riverpod container is created before the app widget so that the
  // BackgroundSyncCoordinator singleton can be shared with LocalServiceRunner,
  // ensuring a single Sync authority on Desktop.
  final container = ProviderContainer();

  // Initialize Local Service for Desktop — passes the shared coordinator.
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final sharedCoordinator =
          container.read(backgroundSyncCoordinatorProvider);
      final localService = LocalServiceRunner(
        port: 8080,
        coordinator: sharedCoordinator,
      );
      await localService.start();
    } catch (e) {
      debugPrint('Local Service initialization error: $e');
    }
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: ModularApp(
        module: AppModule(),
        child: const AppWidget(),
      ),
    ),
  );
}
