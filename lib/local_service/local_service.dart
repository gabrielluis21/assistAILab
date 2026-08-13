// Conditional import: uses dart:io implementation on native platforms,
// falls back to a no-op stub on Web.
export 'local_service_stub.dart'
    if (dart.library.io) 'local_service_runner.dart';
