import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

abstract final class AppEnv {
  static String get appEnvironment => _required('APP_ENV');

  static String get apiScheme =>
      _required('CENTRAL_API_SCHEME');

  static int get apiPort =>
      _requiredInt('CENTRAL_API_PORT');

  static String get apiPrefix =>
      _normalizePrefix(
        _required('CENTRAL_API_PREFIX'),
      );

  static int get apiTimeoutSeconds =>
      _requiredInt('API_TIMEOUT_SECONDS');

  static String get apiHost {
    if (kIsWeb) {
      return _required('CENTRAL_API_HOST_MOBILE');
    }

    if (Platform.isWindows ||
        Platform.isLinux ||
        Platform.isMacOS) {
      return _required(
        'CENTRAL_API_HOST_DESKTOP',
      );
    }

    if (Platform.isAndroid ||
        Platform.isIOS) {
      return _required(
        'CENTRAL_API_HOST_MOBILE',
      );
    }

    throw UnsupportedError(
      'Plataforma não suportada para Central API.',
    );
  }

  static String get apiBaseUrl {
    return '$apiScheme://$apiHost:$apiPort$apiPrefix';
  }

  static String get localServiceBaseUrl {
    final scheme =
        _required('LOCAL_SERVICE_SCHEME');

    final host =
        _required('LOCAL_SERVICE_HOST');

    final port =
        _requiredInt('LOCAL_SERVICE_PORT');

    return '$scheme://$host:$port';
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
        'Environment variable "$key" '
        'must be an integer. '
        'Received: "$rawValue".',
      );
    }

    return value;
  }

  static String _normalizePrefix(
    String prefix,
  ) {
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