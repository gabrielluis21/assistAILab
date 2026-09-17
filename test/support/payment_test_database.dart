import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openPaymentTestDatabase() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE payments (
            id TEXT PRIMARY KEY,
            service_order_id TEXT NOT NULL,
            customer_id TEXT NOT NULL,
            amount_minor INTEGER NOT NULL,
            method TEXT NOT NULL,
            status TEXT NOT NULL,
            notes TEXT,
            paid_at TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE payment_command_intents (
            operation_id TEXT PRIMARY KEY,
            command_type TEXT NOT NULL,
            target_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            lifecycle_state TEXT NOT NULL CHECK (
              lifecycle_state IN (
                'PENDING', 'SENDING', 'UNKNOWN', 'COMPLETED', 'REJECTED'
              )
            ),
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE UNIQUE INDEX payment_command_intents_unresolved_identity
          ON payment_command_intents(command_type, target_id, payload_json)
          WHERE lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')
        ''');
      },
    ),
  );
}
