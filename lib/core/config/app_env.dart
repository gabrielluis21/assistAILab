import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract final class AppEnv {
  static String get environment =>
      dotenv.env['APP_ENV'] ?? 'development';

  static String get apiScheme =>
      dotenv.env['API_SCHEME'] ?? 'http';

  static String get apiHost =>
      dotenv.env['API_HOST'] ?? '127.0.0.1';

  static int get apiPort =>
      int.tryParse(dotenv.env['API_PORT'] ?? '') ?? 3000;

  static String get apiPrefix =>
      dotenv.env['API_PREFIX'] ?? '/api/v1';

  static int get apiTimeoutSeconds =>
      int.tryParse(
        dotenv.env['API_TIMEOUT_SECONDS'] ?? '',
      ) ??
      15;

  static String get apiBaseUrl {
    final prefix = apiPrefix.startsWith('/')
        ? apiPrefix
        : '/$apiPrefix';

    return '$apiScheme://$apiHost:$apiPort$prefix';
  }
}