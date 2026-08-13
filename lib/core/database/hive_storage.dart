import 'package:hive_flutter/hive_flutter.dart';

class HiveStorage {
  static const String preferencesBoxName = 'user_preferences';

  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(preferencesBoxName);
  }

  static Box get _box => Hive.box(preferencesBoxName);

  static Future<void> setDarkMode(bool enabled) async {
    await _box.put('dark_mode', enabled);
  }

  static bool isDarkMode() {
    return _box.get('dark_mode', defaultValue: false) as bool;
  }

  static Future<void> setAuthToken(String token) async {
    await _box.put('auth_token', token);
  }

  static String? getAuthToken() {
    return _box.get('auth_token') as String?;
  }

  static Future<void> setLocalServicePort(int port) async {
    await _box.put('local_service_port', port);
  }

  static int getLocalServicePort() {
    return _box.get('local_service_port', defaultValue: 8080) as int;
  }
}
