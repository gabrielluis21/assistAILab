import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

/// Centraliza as URLs base do AssistAILab por plataforma.
///
/// Não usar 127.0.0.1 para Central API em dispositivos Android físicos.
class ApiEnvironment {
  ApiEnvironment._();

  /// URL base da Central API (Fastify/Node.js, porta 3000).
  static String get centralApiBaseUrl {
    if (kIsWeb) {
      // Web usa API direto (sem LocalService)
      return 'http://127.0.0.1:3000/api/v1';
    }
    if (_isAndroid) {
      // Emulador Android: 10.0.2.2 aponta para o host
      return 'http://10.0.2.2:3000/api/v1';
    }
    // Windows / Linux / macOS / iOS Simulator
    return 'http://127.0.0.1:3000/api/v1';
  }

  /// URL base do LocalService (HTTP loopback do Desktop, porta 8080).
  /// Usado apenas em Desktop.
  static String get localServiceBaseUrl {
    return 'http://127.0.0.1:8080';
  }

  static bool get _isAndroid {
    try {
      return Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }
}
