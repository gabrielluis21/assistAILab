import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_module.dart';
import 'app_widget.dart';
import 'core/database/hive_storage.dart';
import 'local_service/local_service_runner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Hive Storage (Preferences ONLY)
  await HiveStorage.init();

  // Initialize Local Service for Desktop
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    try {
      final localService = LocalServiceRunner(port: 8080);
      await localService.start();
    } catch (e) {
      debugPrint('Local Service initialization error: $e');
    }
  }

  runApp(
    ProviderScope(
      child: ModularApp(
        module: AppModule(),
        child: const AppWidget(),
      ),
    ),
  );
}
