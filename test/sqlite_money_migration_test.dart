import 'package:assistailab/core/database/sqlite_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('schema target is v7', () {
    expect(SqliteDatabase.schemaVersion, 7);
  });

  test('v5 migration persists exact integers and removes REAL authority',
      () async {
    final db = await _openLegacy();
    addTearDown(db.close);
    await _seedValidLegacy(db);

    await SqliteDatabase.migrateV5ToV6(db);

    expect(
      (await db.query('service_orders')).single['total_amount_minor'],
      12345,
    );
    expect(
      (await db.query('service_order_items')).single,
      containsPair('unit_price_minor', 1234),
    );
    expect(
      (await db.query('service_order_items')).single,
      containsPair('total_price_minor', 2468),
    );
    expect((await db.query('parts')).single['price_minor'], 999);
    expect((await db.query('parts')).single['cost_price_minor'], 501);
    expect((await db.query('payments')).single['amount_minor'], 1);
    for (final id in ['payment-2', 'payment-3']) {
      await db.insert('payments', {
        'id': id,
        'service_order_id': 'order-1',
        'customer_id': 'customer-1',
        'amount_minor': 1,
        'method': 'PIX',
        'status': 'CONFIRMED',
        'created_at': '2026-09-16T00:00:00Z',
        'updated_at': '2026-09-16T00:00:00Z',
      });
    }
    expect(
      (await db.rawQuery('SELECT SUM(amount_minor) total FROM payments'))
          .single['total'],
      3,
    );
    expect(
      (await db.query('inventory_movements')).single['unit_cost_minor'],
      250,
    );

    for (final tableAndOldColumns in const {
      'service_orders': ['total_amount'],
      'service_order_items': ['unit_price', 'total_price'],
      'parts': ['price', 'cost_price'],
      'payments': ['amount'],
      'inventory_movements': ['unit_cost'],
    }.entries) {
      final columns = await db.rawQuery(
        'PRAGMA table_info(${tableAndOldColumns.key})',
      );
      final names = columns.map((column) => column['name']);
      for (final staleColumn in tableAndOldColumns.value) {
        expect(names, isNot(contains(staleColumn)));
      }
    }

    final outbox = (await db.query('outbox')).single;
    expect(outbox['status'], 'REQUIRES_ATTENTION');
    expect(
      outbox['last_error'],
      'FE02B_LEGACY_MONEY_RECONCILIATION_REQUIRED',
    );
  });

  test('ambiguous legacy precision fails and rolls the whole migration back',
      () async {
    final db = await _openLegacy();
    addTearDown(db.close);
    await db.insert('service_orders', {
      'id': 'order-ambiguous',
      'customer_id': 'customer',
      'equipment_id': 'equipment',
      'status': 'DIAGNOSTICO',
      'problem_description': 'Problem',
      'total_amount': 0.1 + 0.2,
      'updated_at': '2026-09-16T00:00:00Z',
    });

    await expectLater(
      SqliteDatabase.migrateV5ToV6(db),
      throwsFormatException,
    );

    final columns = await db.rawQuery('PRAGMA table_info(service_orders)');
    final names = columns.map((column) => column['name']).toSet();
    expect(names, contains('total_amount'));
    expect(names, isNot(contains('total_amount_minor')));
    expect(
      (await db.query('service_orders')).single['total_amount'],
      0.1 + 0.2,
    );
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE name LIKE '%_v6'",
      ),
      isEmpty,
    );
  });
}

Future<Database> _openLegacy() {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 5,
      onCreate: (db, _) => _createLegacySchema(db),
    ),
  );
}

Future<void> _createLegacySchema(Database db) async {
  await db.execute('''CREATE TABLE outbox (
    operation_id TEXT PRIMARY KEY, device_id TEXT, user_id TEXT,
    entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
    operation_type TEXT NOT NULL, payload TEXT NOT NULL,
    created_at TEXT NOT NULL, attempt_count INTEGER NOT NULL DEFAULT 0,
    last_attempt_at TEXT, next_retry_at TEXT, last_error TEXT,
    status TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE service_orders (
    id TEXT PRIMARY KEY, friendly_id INTEGER, organization_id TEXT,
    customer_id TEXT NOT NULL, equipment_id TEXT NOT NULL,
    technician_id TEXT, status TEXT NOT NULL,
    problem_description TEXT NOT NULL, diagnosis TEXT, solution TEXT,
    total_amount REAL NOT NULL DEFAULT 0.0, updated_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE service_order_items (
    id TEXT PRIMARY KEY, service_order_id TEXT NOT NULL, part_id TEXT,
    description TEXT NOT NULL, quantity INTEGER NOT NULL DEFAULT 1,
    unit_price REAL NOT NULL DEFAULT 0.0,
    total_price REAL NOT NULL DEFAULT 0.0, updated_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE parts (
    id TEXT PRIMARY KEY, name TEXT NOT NULL, sku TEXT NOT NULL,
    price REAL NOT NULL DEFAULT 0.0, cost_price REAL NOT NULL DEFAULT 0.0,
    stock_quantity INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE payments (
    id TEXT PRIMARY KEY, service_order_id TEXT NOT NULL,
    customer_id TEXT NOT NULL, amount REAL NOT NULL DEFAULT 0.0,
    method TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'PENDING', notes TEXT,
    paid_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
  await db.execute('''CREATE TABLE inventory_movements (
    id TEXT PRIMARY KEY, part_id TEXT NOT NULL, service_order_id TEXT,
    movement_type TEXT NOT NULL, quantity INTEGER NOT NULL,
    unit_cost REAL NOT NULL DEFAULT 0.0, notes TEXT,
    created_at TEXT NOT NULL)''');
}

Future<void> _seedValidLegacy(Database db) async {
  await db.insert('service_orders', {
    'id': 'order',
    'customer_id': 'customer',
    'equipment_id': 'equipment',
    'status': 'DIAGNOSTICO',
    'problem_description': 'Problem',
    'total_amount': 123.45,
    'updated_at': '2026-09-16T00:00:00Z',
  });
  await db.insert('service_order_items', {
    'id': 'item',
    'service_order_id': 'order',
    'description': 'Labor',
    'quantity': 2,
    'unit_price': 12.34,
    'total_price': 24.68,
    'updated_at': '2026-09-16T00:00:00Z',
  });
  await db.insert('parts', {
    'id': 'part',
    'name': 'Part',
    'sku': 'SKU',
    'price': 9.99,
    'cost_price': 5.01,
    'stock_quantity': 1,
    'updated_at': '2026-09-16T00:00:00Z',
  });
  await db.insert('payments', {
    'id': 'payment',
    'service_order_id': 'order',
    'customer_id': 'customer',
    'amount': 0.01,
    'method': 'PIX',
    'status': 'PENDING',
    'created_at': '2026-09-16T00:00:00Z',
    'updated_at': '2026-09-16T00:00:00Z',
  });
  await db.insert('inventory_movements', {
    'id': 'movement',
    'part_id': 'part',
    'movement_type': 'IN',
    'quantity': 1,
    'unit_cost': 2.50,
    'created_at': '2026-09-16T00:00:00Z',
  });
  await db.insert('outbox', {
    'operation_id': 'operation',
    'entity_type': 'PAYMENT',
    'entity_id': 'payment',
    'operation_type': 'CREATE',
    'payload': '{"amount":0.01}',
    'created_at': '2026-09-16T00:00:00Z',
    'status': 'PENDING',
  });
}
