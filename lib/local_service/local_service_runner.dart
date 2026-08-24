import 'dart:convert';
import 'dart:io';
import '../core/database/outbox_dao.dart';
import '../core/sync/sync_engine.dart';
import '../core/sync/background_sync_coordinator.dart';
import '../core/sync/sync_trigger.dart';
import '../core/network/api_client.dart';
import '../core/network/api_environment.dart';

class LocalServiceRunner {
  final int port;
  final String remoteApiUrl;
  HttpServer? _server;
  late final OutboxDao _outboxDao;
  late final SyncEngine _syncEngine;
  late final BackgroundSyncCoordinator _coordinator;
  late final ApiClient _apiClient;

  LocalServiceRunner({
    this.port = 8080,
    String? remoteApiUrl,
  }) : remoteApiUrl = remoteApiUrl ?? ApiEnvironment.centralApiBaseUrl {
    _outboxDao = OutboxDao();
    _apiClient = ApiClient(baseUrl: this.remoteApiUrl);
    _syncEngine = SyncEngine(apiClient: _apiClient, outboxDao: _outboxDao);
    _coordinator = BackgroundSyncCoordinator(
      syncEngine: _syncEngine,
      outboxDao: _outboxDao,
    );
  }

  Future<void> start() async {
    await _coordinator.initialize();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    print('📍 Desktop Local Service listening on http://127.0.0.1:$port');

    _server?.listen((HttpRequest request) async {
      final path = request.uri.path;
      final method = request.method;

      // Add CORS headers for Local Loopback
      request.response.headers.add('Access-Control-Allow-Origin', '*');
      request.response.headers
          .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      request.response.headers
          .add('Access-Control-Allow-Headers', 'Content-Type, Authorization');

      if (method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.ok;
        await request.response.close();
        return;
      }

      if (path == '/health' && method == 'GET') {
        _sendJsonResponse(request.response, HttpStatus.ok, {
          'status': 'HEALTHY',
          'service': 'AssistAILab Desktop Local Service',
          'port': port,
          'syncState': {
            'status': _coordinator.state.status.name,
            'isSyncing': _coordinator.state.isSyncing,
            'pendingOutboxCount': _coordinator.state.pendingOutboxCount,
            'lastSyncAt': _coordinator.state.lastSyncAt?.toIso8601String(),
            'lastError': _coordinator.state.lastError,
          },
          'timestamp': DateTime.now().toIso8601String(),
        });
      } else if (path == '/sync/trigger' && method == 'POST') {
        try {
          await _coordinator.requestSync(SyncTrigger.manual);
          _sendJsonResponse(
              request.response, HttpStatus.ok, {'status': 'SYNC_TRIGGERED'});
        } catch (e) {
          _sendJsonResponse(request.response, HttpStatus.internalServerError,
              {'error': e.toString()});
        }
      } else {
        _sendJsonResponse(request.response, HttpStatus.notFound,
            {'error': 'Route not found'});
      }
    });
  }

  void _sendJsonResponse(
      HttpResponse response, int statusCode, Map<String, dynamic> body) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    response.close();
  }

  Future<void> stop() async {
    _coordinator.dispose();
    await _server?.close();
  }
}
