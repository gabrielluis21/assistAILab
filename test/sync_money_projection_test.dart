import 'package:assistailab/core/sync/sync_projection_applier.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('hydrates exact minor units and full item aggregate', () async {
    final db = await _openProjectionDb();
    addTearDown(db.close);
    await SyncProjectionApplier.applyRecord(db, _staffOrder());

    expect(
      (await db.query('service_orders')).single['total_amount_minor'],
      2468,
    );
    final item = (await db.query('service_order_items')).single;
    expect(item['unit_price_minor'], 1234);
    expect(item['total_price_minor'], 2468);
  });

  test('missing or floating authoritative money is rejected atomically',
      () async {
    for (final invalid in <Object?>[null, 1234.0, '1234']) {
      final db = await _openProjectionDb();
      addTearDown(db.close);
      final record = _staffOrder();
      (record['data'] as Map<String, dynamic>)['totalAmountMinor'] = invalid;
      await expectLater(
        SyncProjectionApplier.applyRecord(db, record),
        throwsA(anything),
      );
      expect(await db.query('service_orders'), isEmpty);
    }
  });

  test('CUSTOMER minimized projection does not fabricate private identities',
      () async {
    final db = await _openProjectionDb();
    addTearDown(db.close);
    final record = _staffOrder();
    final data = record['data'] as Map<String, dynamic>;
    data.remove('organizationId');
    data.remove('customerId');
    data.remove('technicianId');
    data.remove('currentQuoteRevisionId');
    data.remove('lastApprovedQuoteRevisionId');
    data.remove('materializedQuoteRevisionId');
    data.remove('commercialScopeSource');
    data['items'] = [
      {
        'description': 'Labor',
        'quantity': 2,
        'unitPriceMinor': 1234,
        'totalPriceMinor': 2468,
      },
    ];

    await SyncProjectionApplier.applyRecord(db, record);
    final order = (await db.query('service_orders')).single;
    final item = (await db.query('service_order_items')).single;
    expect(order['customer_id'], isNull);
    expect(order['organization_id'], isNull);
    expect(order['technician_id'], isNull);
    expect(item['part_id'], isNull);
    expect(item['id'], 'customer:order-1:0');
  });

  test('equal revision must be canonically identical', () async {
    final db = await _openProjectionDb();
    addTearDown(db.close);
    await SyncProjectionApplier.applyRecord(db, _staffOrder());
    await SyncProjectionApplier.applyRecord(db, _staffOrder());
    final divergent = _staffOrder();
    (divergent['data'] as Map<String, dynamic>)['problemDescription'] =
        'Different';
    await expectLater(
      SyncProjectionApplier.applyRecord(db, divergent),
      throwsA(
        isA<SyncProjectionException>().having(
          (error) => error.code,
          'code',
          'SYNC_EQUAL_REVISION_DIVERGED',
        ),
      ),
    );
  });

  test('Payment requires amountMinor integer', () async {
    final db = await _openProjectionDb();
    addTearDown(db.close);
    final payment = {
      'entityType': 'PAYMENT',
      'entityId': 'payment-1',
      'data': {
        'id': 'payment-1',
        'serviceOrderId': 'order-1',
        'customerId': 'customer-1',
        'amountMinor': 1,
        'method': 'PIX',
        'status': 'PENDING',
        'notes': null,
        'paidAt': null,
        'createdAt': '2026-09-16T00:00:00Z',
        'updatedAt': '2026-09-16T00:00:00Z',
      },
    };
    await SyncProjectionApplier.applyRecord(db, payment);
    expect((await db.query('payments')).single['amount_minor'], 1);

    (payment['data'] as Map<String, dynamic>)['amountMinor'] = 1.0;
    await expectLater(
      SyncProjectionApplier.applyRecord(db, payment),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _staffOrder() => {
      'entityType': 'SERVICE_ORDER',
      'entityId': 'order-1',
      'data': {
        'contractVersion': 2,
        'projectionRevision': '9007199254740993',
        'id': 'order-1',
        'friendlyId': 10,
        'organizationId': 'organization-1',
        'customerId': 'customer-1',
        'equipmentId': 'equipment-1',
        'technicianId': null,
        'status': 'DIAGNOSTICO',
        'problemDescription': 'Problem',
        'diagnosis': 'Diagnosis',
        'solution': null,
        'totalAmountMinor': 2468,
        'currentQuoteRevisionId': null,
        'lastApprovedQuoteRevisionId': null,
        'materializedQuoteRevisionId': null,
        'commercialScopeSource': 'UNPUBLISHED',
        'createdAt': '2026-09-16T00:00:00Z',
        'updatedAt': '2026-09-16T00:00:00Z',
        'items': [
          {
            'id': 'item-1',
            'serviceOrderId': 'order-1',
            'partId': null,
            'description': 'Labor',
            'quantity': 2,
            'unitPriceMinor': 1234,
            'totalPriceMinor': 2468,
            'createdAt': '2026-09-16T00:00:00Z',
          },
        ],
      },
    };

Future<Database> _openProjectionDb() {
  return databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE customers (
          id TEXT PRIMARY KEY, name TEXT NOT NULL, document TEXT, email TEXT,
          phone TEXT, address TEXT, updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE equipments (
          id TEXT PRIMARY KEY, customer_id TEXT, organization_id TEXT,
          owner_type TEXT NOT NULL, organization_purpose TEXT, type TEXT NOT NULL,
          brand TEXT NOT NULL, model TEXT NOT NULL, serial_number TEXT,
          notes TEXT, updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE service_orders (
          id TEXT PRIMARY KEY, friendly_id INTEGER, organization_id TEXT,
          customer_id TEXT, equipment_id TEXT NOT NULL, technician_id TEXT,
          status TEXT NOT NULL, problem_description TEXT NOT NULL,
          diagnosis TEXT, solution TEXT, total_amount_minor INTEGER NOT NULL,
          projection_revision TEXT, projection_fingerprint TEXT,
          updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE service_order_items (
          id TEXT PRIMARY KEY, service_order_id TEXT NOT NULL, part_id TEXT,
          description TEXT NOT NULL, quantity INTEGER NOT NULL,
          unit_price_minor INTEGER NOT NULL, total_price_minor INTEGER NOT NULL,
          updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE payments (
          id TEXT PRIMARY KEY, service_order_id TEXT NOT NULL,
          customer_id TEXT NOT NULL, amount_minor INTEGER NOT NULL,
          method TEXT NOT NULL, status TEXT NOT NULL, notes TEXT, paid_at TEXT,
          created_at TEXT NOT NULL, updated_at TEXT NOT NULL)''');
        await db.execute('''CREATE TABLE outbox (
          operation_id TEXT PRIMARY KEY, entity_type TEXT NOT NULL,
          entity_id TEXT NOT NULL, operation_type TEXT NOT NULL,
          payload TEXT NOT NULL, created_at TEXT NOT NULL,
          status TEXT NOT NULL)''');
      },
    ),
  );
}
