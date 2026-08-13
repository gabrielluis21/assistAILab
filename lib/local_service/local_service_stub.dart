// Stub for platforms that don't support the Local Service (Web, Mobile).
// On Desktop, the real LocalServiceRunner from local_service_runner.dart is used.

class LocalServiceRunner {
  final int port;
  final String remoteApiUrl;

  LocalServiceRunner({this.port = 8080, this.remoteApiUrl = ''});

  Future<void> start() async {
    // No-op on Web and Mobile platforms.
  }

  Future<void> stop() async {
    // No-op on Web and Mobile platforms.
  }
}
