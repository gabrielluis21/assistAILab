import 'package:flutter/foundation.dart' show kIsWeb;

/// Throws an [UnsupportedError] if SQLite access is attempted on Web.
/// This function should be called at the start of any SQLite‑dependent method.
void assertWebNoSqlite() {
  if (kIsWeb) {
    throw UnsupportedError('SQLite is not available on the Web platform. Use the API directly.');
  }
}
