import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sqlite_database_io.dart'
    if (dart.library.html) 'sqlite_database_web.dart';

class SqliteDatabase {
  static Database? _database;

  static Future<Database> get instance async {
    if (_database != null) return _database!;

    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    if (kIsWeb) {
      throw UnsupportedError(
        'SQLite is not available on the Web platform. Use the API directly.',
      );
    }

    if (isDesktopPlatform()) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await _getDbPath();

    return openDatabase(
      dbPath,
      version: 5,
      onCreate: (db, version) async {
        await _createTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Garante existência das tabelas antes das migrations incrementais.
        await _createTables(db);

        if (oldVersion < 4) {
          await _migrateV3ToV4(db);
        }

        if (oldVersion < 5) {
          await _migrateV4ToV5(db);
        }
      },
      onOpen: (db) async {
        await _createTables(db);

        // Compatibilidade defensiva para instalações antigas que
        // já estavam marcadas como v4 com schema físico incompleto.
        await _ensureV5Schema(db);
      },
    );
  }

  static Future<String> _getDbPath() async {
    return getLocalDbPath('assistailab_local.db');
  }

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS outbox (
        operation_id TEXT PRIMARY KEY,
        device_id TEXT,
        user_id TEXT,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation_type TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_attempt_at TEXT,
        next_retry_at TEXT,
        last_error TEXT,
        status TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS customers (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        document TEXT,
        email TEXT,
        phone TEXT,
        address TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS service_orders (
        id TEXT PRIMARY KEY,
        friendly_id INTEGER,
        organization_id TEXT,
        customer_id TEXT NOT NULL,
        equipment_id TEXT NOT NULL,
        technician_id TEXT,
        status TEXT NOT NULL,
        problem_description TEXT NOT NULL,
        diagnosis TEXT,
        solution TEXT,
        total_amount REAL NOT NULL DEFAULT 0.0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS equipments (
        id TEXT PRIMARY KEY,
        customer_id TEXT,
        organization_id TEXT,
        owner_type TEXT NOT NULL DEFAULT 'CUSTOMER',
        organization_purpose TEXT,
        type TEXT NOT NULL,
        brand TEXT NOT NULL,
        model TEXT NOT NULL,
        serial_number TEXT,
        notes TEXT,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS service_order_items (
        id TEXT PRIMARY KEY,
        service_order_id TEXT NOT NULL,
        part_id TEXT,
        description TEXT NOT NULL,
        quantity INTEGER NOT NULL DEFAULT 1,
        unit_price REAL NOT NULL DEFAULT 0.0,
        total_price REAL NOT NULL DEFAULT 0.0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS parts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sku TEXT NOT NULL,
        price REAL NOT NULL DEFAULT 0.0,
        cost_price REAL NOT NULL DEFAULT 0.0,
        stock_quantity INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS payments (
        id TEXT PRIMARY KEY,
        service_order_id TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        amount REAL NOT NULL DEFAULT 0.0,
        method TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'PENDING',
        notes TEXT,
        paid_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS inventory_movements (
        id TEXT PRIMARY KEY,
        part_id TEXT NOT NULL,
        service_order_id TEXT,
        movement_type TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        unit_cost REAL NOT NULL DEFAULT 0.0,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  /// v3 → v4
  ///
  /// Introduziu ownership de Equipment.
  static Future<void> _migrateV3ToV4(Database db) async {
    final columns = await _columnNames(db, 'equipments');

    if (!columns.contains('organization_id')) {
      await db.execute(
        'ALTER TABLE equipments '
        'ADD COLUMN organization_id TEXT',
      );
    }

    if (!columns.contains('owner_type')) {
      await db.execute(
        'ALTER TABLE equipments '
        "ADD COLUMN owner_type TEXT NOT NULL DEFAULT 'CUSTOMER'",
      );
    }

    if (!columns.contains('organization_purpose')) {
      await db.execute(
        'ALTER TABLE equipments '
        'ADD COLUMN organization_purpose TEXT',
      );
    }
  }

  /// v4 → v5
  ///
  /// - completa o schema persistente da Outbox;
  /// - adiciona organization_id à projeção local de ServiceOrder.
  static Future<void> _migrateV4ToV5(Database db) async {
    await _ensureV5Schema(db);
  }

  /// Garante que instalações antigas possuam o schema mínimo
  /// esperado pelo código Flutter atual.
  ///
  /// Idempotente: nenhuma coluna existente é recriada.
  static Future<void> _ensureV5Schema(Database db) async {
    await _ensureOutboxRetryColumns(db);
    await _ensureServiceOrderOrganizationColumn(db);
  }

  static Future<void> _ensureOutboxRetryColumns(Database db) async {
    final columns = await _columnNames(db, 'outbox');

    if (!columns.contains('attempt_count')) {
      await db.execute(
        'ALTER TABLE outbox '
        'ADD COLUMN attempt_count INTEGER NOT NULL DEFAULT 0',
      );
    }

    if (!columns.contains('last_attempt_at')) {
      await db.execute(
        'ALTER TABLE outbox '
        'ADD COLUMN last_attempt_at TEXT',
      );
    }

    if (!columns.contains('next_retry_at')) {
      await db.execute(
        'ALTER TABLE outbox '
        'ADD COLUMN next_retry_at TEXT',
      );
    }

    if (!columns.contains('last_error')) {
      await db.execute(
        'ALTER TABLE outbox '
        'ADD COLUMN last_error TEXT',
      );
    }
  }

  static Future<void> _ensureServiceOrderOrganizationColumn(
    Database db,
  ) async {
    final columns = await _columnNames(db, 'service_orders');

    if (!columns.contains('organization_id')) {
      await db.execute(
        'ALTER TABLE service_orders '
        'ADD COLUMN organization_id TEXT',
      );
    }
  }

  static Future<Set<String>> _columnNames(
    Database db,
    String table,
  ) async {
    final result = await db.rawQuery(
      'PRAGMA table_info($table)',
    );

    return result.map((column) => column['name'] as String).toSet();
  }
}
