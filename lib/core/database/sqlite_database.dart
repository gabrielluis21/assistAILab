import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../commands/command_intent.dart';
import 'assert_web_no_sqlite.dart';
import 'auth_scoped_database_manager.dart';
import '../money/legacy_money_major_adapter.dart';
import '../money/money_minor.dart';

import 'sqlite_database_io.dart'
    if (dart.library.html) 'sqlite_database_web.dart';

class SqliteDatabase {
  static const schemaVersion = 7;

  /// Retorna o banco de dados ativo no [AuthScopedDatabaseManager].
  ///
  /// Lança [StateError] se nenhum escopo válido estiver ativo.
  static Future<Database> get instance async {
    assertWebNoSqlite();
    return AuthScopedDatabaseManager.instance.activeDatabase;
  }

  /// Abre e inicializa o banco de dados SQLite com o nome [dbFileName] especificado,
  /// aplicando o schema e migrations necessárias.
  static Future<Database> openDatabaseByName(String dbFileName) async {
    if (kIsWeb) {
      throw UnsupportedError(
        'SQLite is not available on the Web platform. Use the API directly.',
      );
    }

    if (isDesktopPlatform()) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getLocalDbPath(dbFileName);

    return openDatabase(
      dbPath,
      version: schemaVersion,
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

        if (oldVersion < 6) {
          await _migrateV5ToV6(db);
        }

        if (oldVersion < 7) {
          await _migrateV6ToV7(db, requireLegacyTable: oldVersion >= 6);
        }
      },
      onOpen: (db) async {
        await _createTables(db);

        // Compatibilidade defensiva para instalações antigas que
        // já estavam marcadas como v4 com schema físico incompleto.
        await _verifyV7Schema(db);
      },
    );
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

    await _createPreAcquisitionTable(db);

    await db.execute('''
      CREATE TABLE IF NOT EXISTS service_order_items (
        id TEXT PRIMARY KEY,
        service_order_id TEXT NOT NULL,
        part_id TEXT,
        description TEXT NOT NULL,
        quantity INTEGER NOT NULL DEFAULT 1,
        unit_price_minor INTEGER NOT NULL,
        total_price_minor INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS parts (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sku TEXT NOT NULL,
        price_minor INTEGER NOT NULL,
        cost_price_minor INTEGER NOT NULL,
        stock_quantity INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS payments (
        id TEXT PRIMARY KEY,
        service_order_id TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        amount_minor INTEGER NOT NULL,
        method TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'PENDING',
        notes TEXT,
        paid_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await _createCommandIntentTable(db);

    await db.execute('''
      CREATE TABLE IF NOT EXISTS inventory_movements (
        id TEXT PRIMARY KEY,
        part_id TEXT NOT NULL,
        service_order_id TEXT,
        movement_type TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        unit_cost_minor INTEGER NOT NULL,
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

  static Future<void> _createCommandIntentTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS command_intents (
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
      CREATE UNIQUE INDEX IF NOT EXISTS
        command_intents_unresolved_identity
      ON command_intents(command_type, target_id, payload_json)
      WHERE lifecycle_state IN ('PENDING', 'SENDING', 'UNKNOWN')
    ''');
  }

  static Future<void> _createPreAcquisitionTable(
    DatabaseExecutor db,
  ) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pre_acquisitions (
        id TEXT PRIMARY KEY,
        equipment_id TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        organization_id TEXT NOT NULL,
        service_order_id TEXT,
        status TEXT NOT NULL CHECK (
          status IN (
            'PENDING_EVALUATION', 'APPROVED', 'REJECTED', 'EXPIRED',
            'CANCELLED'
          )
        ),
        offered_amount_minor INTEGER CHECK (
          offered_amount_minor IS NULL OR offered_amount_minor >= 0
        ),
        notes TEXT,
        created_at TEXT NOT NULL,
        evaluation_deadline TEXT NOT NULL,
        evaluated_at TEXT,
        resolution_reason TEXT
      )
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS pre_acquisitions_equipment
      ON pre_acquisitions(equipment_id)
    ''');
    await db.execute('''
      CREATE INDEX IF NOT EXISTS pre_acquisitions_status_deadline
      ON pre_acquisitions(status, evaluation_deadline)
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

  /// Public transaction wrapper used by deterministic migration tests and
  /// repair tooling. Normal `onUpgrade` already runs in a SQLite transaction
  /// and therefore calls [_migrateV5ToV6] directly.
  static Future<void> migrateV5ToV6(Database db) =>
      db.transaction(_migrateV5ToV6);

  /// Transactional v6 -> v7 durable command migration. Exposed for
  /// deterministic migration tests; normal upgrades use the same body inside
  /// sqflite's upgrade transaction.
  static Future<void> migrateV6ToV7(Database db) => db.transaction((txn) async {
        await _createCommandIntentTable(txn);
        await _migrateV6ToV7(txn, requireLegacyTable: true);
      });

  /// Idempotent additive schema migration for the local-only pre-acquisition
  /// workflow. The baseline keeps schema version 7, while [_createTables]
  /// applies this extension to new, upgraded and already-current databases.
  static Future<void> ensurePreAcquisitionSchema(Database db) =>
      db.transaction(_createPreAcquisitionTable);

  static Future<void> _migrateV5ToV6(DatabaseExecutor db) async {
    final serviceOrders = await _convertedRows(
      db,
      'service_orders',
      const {'total_amount': 'total_amount_minor'},
      maximum: MoneyMinor.serviceOrderMaximum,
    );
    final serviceOrderItems = await _convertedRows(
      db,
      'service_order_items',
      const {
        'unit_price': 'unit_price_minor',
        'total_price': 'total_price_minor',
      },
      maximum: MoneyMinor.serviceOrderMaximum,
    );
    final parts = await _convertedRows(
      db,
      'parts',
      const {'price': 'price_minor', 'cost_price': 'cost_price_minor'},
      maximum: MoneyMinor.serviceOrderMaximum,
    );
    final payments = await _convertedRows(
      db,
      'payments',
      const {'amount': 'amount_minor'},
    );
    final inventoryMovements = await _convertedRows(
      db,
      'inventory_movements',
      const {'unit_cost': 'unit_cost_minor'},
      maximum: MoneyMinor.serviceOrderMaximum,
    );

    await db.execute('''
      CREATE TABLE service_orders_v6 (
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
      CREATE TABLE service_order_items_v6 (
        id TEXT PRIMARY KEY,
        service_order_id TEXT NOT NULL,
        part_id TEXT,
        description TEXT NOT NULL,
        quantity INTEGER NOT NULL DEFAULT 1,
        unit_price_minor INTEGER NOT NULL,
        total_price_minor INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE parts_v6 (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        sku TEXT NOT NULL,
        price_minor INTEGER NOT NULL,
        cost_price_minor INTEGER NOT NULL,
        stock_quantity INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE payments_v6 (
        id TEXT PRIMARY KEY,
        service_order_id TEXT NOT NULL,
        customer_id TEXT NOT NULL,
        amount_minor INTEGER NOT NULL,
        method TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'PENDING',
        notes TEXT,
        paid_at TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE inventory_movements_v6 (
        id TEXT PRIMARY KEY,
        part_id TEXT NOT NULL,
        service_order_id TEXT,
        movement_type TEXT NOT NULL,
        quantity INTEGER NOT NULL,
        unit_cost_minor INTEGER NOT NULL,
        notes TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    await _insertRows(db, 'service_orders_v6', serviceOrders);
    await _insertRows(db, 'service_order_items_v6', serviceOrderItems);
    await _insertRows(db, 'parts_v6', parts);
    await _insertRows(db, 'payments_v6', payments);
    await _insertRows(db, 'inventory_movements_v6', inventoryMovements);

    for (final table in const [
      'service_orders',
      'service_order_items',
      'parts',
      'payments',
      'inventory_movements',
    ]) {
      await db.execute('DROP TABLE $table');
      await db.execute('ALTER TABLE ${table}_v6 RENAME TO $table');
    }

    // Pre-v2 money-bearing intents cannot be replayed against the v2 minor
    // contract. Preserve them verbatim for explicit reconciliation.
    final outboxRows = await db.query(
      'outbox',
      where: "status IN ('PENDING', 'PROCESSING', 'FAILED')",
    );
    for (final row in outboxRows) {
      final entityType = (row['entity_type'] as String).toUpperCase();
      final rawPayload = row['payload'];
      var hasLegacyMoney = entityType == 'PAYMENT' || entityType == 'PART';
      if (rawPayload is String) {
        final decoded = jsonDecode(rawPayload);
        if (decoded is Map) {
          hasLegacyMoney = hasLegacyMoney ||
              const {
                'amount',
                'price',
                'costPrice',
                'cost_price',
                'unitPrice',
                'unit_price',
                'totalPrice',
                'total_price',
                'totalAmount',
                'total_amount',
                'unitCost',
                'unit_cost',
              }.any(decoded.containsKey);
        }
      }
      if (hasLegacyMoney) {
        await db.update(
          'outbox',
          {
            'status': 'REQUIRES_ATTENTION',
            'last_error': 'FE02B_LEGACY_MONEY_RECONCILIATION_REQUIRED',
            'next_retry_at': null,
          },
          where: 'operation_id = ?',
          whereArgs: [row['operation_id']],
        );
      }
    }
  }

  static Future<void> _migrateV6ToV7(
    DatabaseExecutor db, {
    required bool requireLegacyTable,
  }) async {
    final legacyExists = await _tableExists(db, 'payment_command_intents');
    if (!legacyExists) {
      if (requireLegacyTable) {
        throw StateError(
          'SQLite v6 payment command authority table is missing.',
        );
      }
      if ((await db.query('command_intents')).isNotEmpty) {
        throw StateError('Unexpected command authority before v7 migration.');
      }
      return;
    }

    const expectedColumns = {
      'operation_id',
      'command_type',
      'target_id',
      'payload_json',
      'lifecycle_state',
      'created_at',
      'updated_at',
    };
    final legacyColumns = await _columnNames(db, 'payment_command_intents');
    if (legacyColumns.length != expectedColumns.length ||
        !legacyColumns.containsAll(expectedColumns)) {
      throw StateError('SQLite v6 payment command schema is malformed.');
    }
    if ((await db.query('command_intents')).isNotEmpty) {
      throw StateError('SQLite v7 command authority is not empty.');
    }

    const commandMapping = {
      'CREATE': 'PAYMENT_CREATE',
      'CONFIRM': 'PAYMENT_CONFIRM',
      'CANCEL': 'PAYMENT_CANCEL',
    };
    final legacyRows = await db.query(
      'payment_command_intents',
      orderBy: 'created_at, operation_id',
    );
    final migratedRows = <Map<String, Object?>>[];
    final unresolvedIdentities = <String>{};
    for (final legacy in legacyRows) {
      final mappedType = commandMapping[legacy['command_type']];
      if (mappedType == null) {
        throw const FormatException(
          'Unsupported legacy Payment command type.',
        );
      }
      final mapped = <String, Object?>{
        'operation_id': legacy['operation_id'],
        'command_type': mappedType,
        'target_id': legacy['target_id'],
        'payload_json': legacy['payload_json'],
        'lifecycle_state': legacy['lifecycle_state'],
        'created_at': legacy['created_at'],
        'updated_at': legacy['updated_at'],
      };
      final intent = CommandIntent.fromMap(mapped);
      if (intent.lifecycle.isUnresolved) {
        final identity = '${intent.commandType}\u0000${intent.targetId}'
            '\u0000${intent.canonicalPayload}';
        if (!unresolvedIdentities.add(identity)) {
          throw StateError(
            'Contradictory unresolved legacy command identity.',
          );
        }
      }
      migratedRows.add(mapped);
    }

    for (final row in migratedRows) {
      await db.insert('command_intents', row);
    }
    final verification = await db.query(
      'command_intents',
      orderBy: 'created_at, operation_id',
    );
    if (verification.length != migratedRows.length) {
      throw StateError('SQLite v7 command migration count mismatch.');
    }
    for (var index = 0; index < verification.length; index++) {
      final expected = migratedRows[index];
      final actual = verification[index];
      for (final column in expectedColumns) {
        if (actual[column] != expected[column]) {
          throw StateError('SQLite v7 command migration mismatch.');
        }
      }
      CommandIntent.fromMap(actual);
    }

    await db.execute('DROP TABLE payment_command_intents');
    if (await _tableExists(db, 'payment_command_intents')) {
      throw StateError('Legacy Payment command authority was not removed.');
    }
  }

  static Future<List<Map<String, Object?>>> _convertedRows(
    DatabaseExecutor db,
    String table,
    Map<String, String> fields, {
    int maximum = MoneyMinor.generalMaximum,
  }) async {
    final rows = await db.query(table);
    return rows.map((source) {
      final target = Map<String, Object?>.from(source);
      for (final entry in fields.entries) {
        final money = legacySqliteMajorToMinor(
          target.remove(entry.key),
          maximum: maximum,
        );
        target[entry.value] = money.minorUnits;
      }
      return target;
    }).toList(growable: false);
  }

  static Future<void> _insertRows(
    DatabaseExecutor db,
    String table,
    List<Map<String, Object?>> rows,
  ) async {
    for (final row in rows) {
      await db.insert(table, row);
    }
  }

  static Future<void> _verifyV6Schema(Database db) async {
    const expectedMoneyColumns = {
      'service_orders': ['total_amount_minor'],
      'service_order_items': ['unit_price_minor', 'total_price_minor'],
      'parts': ['price_minor', 'cost_price_minor'],
      'payments': ['amount_minor'],
      'inventory_movements': ['unit_cost_minor'],
    };
    const staleColumns = {
      'service_orders': ['total_amount'],
      'service_order_items': ['unit_price', 'total_price'],
      'parts': ['price', 'cost_price'],
      'payments': ['amount'],
      'inventory_movements': ['unit_cost'],
    };
    for (final entry in expectedMoneyColumns.entries) {
      final info = await db.rawQuery('PRAGMA table_info(${entry.key})');
      final columns = {
        for (final column in info) column['name'] as String: column['type'],
      };
      final missingInteger = entry.value.any(
        (column) => columns[column] != 'INTEGER',
      );
      final hasStale = staleColumns[entry.key]!.any(columns.containsKey);
      if (missingInteger || hasStale) {
        throw StateError(
            'SQLite v6 money schema is incomplete for ${entry.key}.');
      }
    }
  }

  static Future<void> _verifyV7Schema(Database db) async {
    await _verifyV6Schema(db);
    if (await _tableExists(db, 'payment_command_intents')) {
      throw StateError('Legacy Payment command authority remains in v7.');
    }
    const expectedColumns = {
      'operation_id',
      'command_type',
      'target_id',
      'payload_json',
      'lifecycle_state',
      'created_at',
      'updated_at',
    };
    final columns = await _columnNames(db, 'command_intents');
    if (columns.length != expectedColumns.length ||
        !columns.containsAll(expectedColumns)) {
      throw StateError('SQLite v7 command intent schema is incomplete.');
    }
    const expectedPreAcquisitionColumns = {
      'id',
      'equipment_id',
      'customer_id',
      'organization_id',
      'service_order_id',
      'status',
      'offered_amount_minor',
      'notes',
      'created_at',
      'evaluation_deadline',
      'evaluated_at',
      'resolution_reason',
    };
    final preAcquisitionColumns = await _columnNames(db, 'pre_acquisitions');
    if (preAcquisitionColumns.length != expectedPreAcquisitionColumns.length ||
        !preAcquisitionColumns.containsAll(expectedPreAcquisitionColumns)) {
      throw StateError(
        'SQLite v7 pre-acquisition extension is incomplete.',
      );
    }
  }

  static Future<bool> _tableExists(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.query(
      'sqlite_master',
      columns: ['name'],
      where: "type = 'table' AND name = ?",
      whereArgs: [table],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<Set<String>> _columnNames(
    DatabaseExecutor db,
    String table,
  ) async {
    final result = await db.rawQuery(
      'PRAGMA table_info($table)',
    );

    return result.map((column) => column['name'] as String).toSet();
  }
}
