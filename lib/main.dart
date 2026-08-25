import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_module.dart';
import 'app_widget.dart';
import 'core/database/hive_storage.dart';
import 'core/sync/sync_providers.dart';
import 'local_service/local_service_runner.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(
    fileName: '.env',
  );

  await HiveStorage.init();

  final container = ProviderContainer();

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
      debugPrint(
        'Local Service initialization error: $e',
      );
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
