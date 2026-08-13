import 'dart:io';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';

bool isDesktopPlatform() {
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

Future<String> getLocalDbPath(String dbName) async {
  if (isDesktopPlatform()) {
    final supportDir = await getApplicationSupportDirectory();
    return join(supportDir.path, dbName);
  } else {
    final dbPath = await getDatabasesPath();
    return join(dbPath, dbName);
  }
}
