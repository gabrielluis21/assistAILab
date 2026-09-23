import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> openCustomerQuoteTestDatabase() async {
  sqfliteFfiInit();
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      singleInstance: false,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE service_orders (
            id TEXT PRIMARY KEY,
            friendly_id INTEGER,
            organization_id TEXT,
            customer_id TEXT,
            equipment_id TEXT NOT NULL,
            technician_id TEXT,
            status TEXT NOT NULL,
            problem_description TEXT NOT NULL,
            diagnosis TEXT,
            solution TEXT,
            total_amount_minor INTEGER NOT NULL,
            projection_revision TEXT,
            projection_fingerprint TEXT,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE service_order_items (
            id TEXT PRIMARY KEY,
            service_order_id TEXT NOT NULL,
            part_id TEXT,
            description TEXT NOT NULL,
            quantity INTEGER NOT NULL,
            unit_price_minor INTEGER NOT NULL,
            total_price_minor INTEGER NOT NULL,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE command_intents (
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
          CREATE TABLE outbox (
            operation_id TEXT PRIMARY KEY,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation_type TEXT NOT NULL,
            payload TEXT NOT NULL,
            created_at TEXT NOT NULL,
            status TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE UNIQUE INDEX command_intents_unresolved_identity
          ON command_intents(command_type, target_id, payload_json)
          WHERE lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')
        ''');
      },
    ),
  );
}
