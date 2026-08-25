import 'package:flutter_dotenv/flutter_dotenv.dart';

class ApiEnvironment {
  ApiEnvironment._();

  static String get appEnvironment {
    return _required('APP_ENV');
  }

  static String get centralApiBaseUrl {
    final scheme = _required('CENTRAL_API_SCHEME');
    final host = _required('CENTRAL_API_HOST');
    final port = _requiredInt('CENTRAL_API_PORT');
    final prefix = _normalizePrefix(
      _required('CENTRAL_API_PREFIX'),
    );

    return '$scheme://$host:$port$prefix';
  }

  static String get localServiceBaseUrl {
    final scheme = _required('LOCAL_SERVICE_SCHEME');
    final host = _required('LOCAL_SERVICE_HOST');
    final port = _requiredInt('LOCAL_SERVICE_PORT');

    return '$scheme://$host:$port';
  }

  static Duration get apiTimeout {
    return Duration(
      seconds: _requiredInt('API_TIMEOUT_SECONDS'),
    );
  }

  static String _required(String key) {
    final value = dotenv.env[key]?.trim();

    if (value == null || value.isEmpty) {
      throw StateError(
        'Environment variable "$key" is required.',
      );
    }

    return value;
  }

  static int _requiredInt(String key) {
    final rawValue = _required(key);
    final value = int.tryParse(rawValue);

    if (value == null) {
      throw StateError(
        'Environment variable "$key" must be an integer. '
        'Received: "$rawValue".',
      );
    }

    return value;
  }

  static String _normalizePrefix(String prefix) {
    if (prefix == '/') {
      return '';
    }

    var normalized = prefix.trim();

    if (!normalized.startsWith('/')) {
      normalized = '/$normalized';
    }

    while (normalized.endsWith('/')) {
      normalized = normalized.substring(
        0,
        normalized.length - 1,
      );
    }

    return normalized;
  }
}
