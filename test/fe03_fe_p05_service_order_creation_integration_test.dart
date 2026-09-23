import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/customers/customer_entity.dart';
import 'package:assistailab/features/customers/customers_provider.dart';
import 'package:assistailab/features/equipment/equipment_entity.dart';
import 'package:assistailab/features/equipment/equipments_provider.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/service_orders_page.dart';
import 'package:assistailab/features/service_orders/service_orders_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeServiceOrdersNotifier extends ServiceOrdersNotifier {
  final calls = <Map<String, Object?>>[];

  @override
  Future<List<ServiceOrderEntity>> build() async => const [];

  @override
  Future<void> createOrder({
    required String customerId,
    required String equipmentId,
    required String problemDescription,
    String? technicianId,
  }) async {
    calls.add({
      'customerId': customerId,
      'equipmentId': equipmentId,
      'problemDescription': problemDescription,
      'technicianId': technicianId,
    });
  }
}

class _FakeCustomersNotifier extends CustomersNotifier {
  _FakeCustomersNotifier(this.customers);

  final List<CustomerEntity> customers;

  @override
  Future<List<CustomerEntity>> build() async => customers;
}

class _FakeEquipmentsNotifier extends EquipmentsNotifier {
  _FakeEquipmentsNotifier(this.equipments);

  final List<EquipmentEntity> equipments;

  @override
  Future<List<EquipmentEntity>> build() async => equipments;
}

const _admin = User(
  id: 'admin-1',
  name: 'Admin',
  email: 'admin@example.com',
  role: 'ADMIN',
  status: 'ACTIVE',
  organizationId: 'org-1',
);

const _technician = User(
  id: 'technician-1',
  name: 'Technician',
  email: 'technician@example.com',
  role: 'TECHNICIAN',
  status: 'ACTIVE',
  organizationId: 'org-1',
);

const _customerUser = User(
  id: 'customer-user-1',
  name: 'Customer',
  email: 'customer@example.com',
  role: 'CUSTOMER',
  status: 'ACTIVE',
  customerId: 'customer-1',
);

void main() {
  late _FakeServiceOrdersNotifier serviceOrders;

  setUp(() {
    serviceOrders = _FakeServiceOrdersNotifier();
  });

  Widget page({
    required User user,
    List<CustomerEntity>? customers,
    List<EquipmentEntity>? equipments,
  }) {
    return ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(user),
        serviceOrdersProvider.overrideWith(() => serviceOrders),
        customersProvider.overrideWith(
          () => _FakeCustomersNotifier(customers ?? [_customer()]),
        ),
        equipmentsProvider.overrideWith(
          () => _FakeEquipmentsNotifier(equipments ?? [_equipment()]),
        ),
      ],
      child: const MaterialApp(home: ServiceOrdersPage()),
    );
  }

  group('creation authorization', () {
    test('only ADMIN and TECHNICIAN satisfy the local creation policy', () {
      expect(canCreateServiceOrder(_admin), isTrue);
      expect(canCreateServiceOrder(_technician), isTrue);
      expect(canCreateServiceOrder(_customerUser), isFalse);
      expect(canCreateServiceOrder(null), isFalse);
    });

    test('provider rejects CUSTOMER before database and Outbox access',
        () async {
      final container = ProviderContainer(
        overrides: [
          currentUserProvider.overrideWithValue(_customerUser),
          authenticatedSessionKeyProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(
        container.read(serviceOrdersProvider.notifier).createOrder(
              customerId: '10000000-0000-4000-8000-000000000001',
              equipmentId: '20000000-0000-4000-8000-000000000001',
              problemDescription: 'Equipamento nao liga',
            ),
        throwsA(isA<StateError>()),
      );
    });

    testWidgets('CUSTOMER cannot open the new service order flow',
        (tester) async {
      await tester.pumpWidget(page(user: _customerUser));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('create_service_order_fab')), findsNothing);
      expect(serviceOrders.calls, isEmpty);
    });

    for (final staff in const [_admin, _technician]) {
      testWidgets('${staff.role} can open the new service order flow',
          (tester) async {
        await tester.pumpWidget(page(user: staff));
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('create_service_order_fab')),
          findsOneWidget,
        );
      });
    }
  });

  group('existing-equipment Sync contract', () {
    test('rejects identifiers that cannot satisfy the backend UUID contract',
        () {
      expect(
        () => validateServiceOrderCreationInput(
          customerId: 'cust-placeholder',
          equipmentId: '20000000-0000-4000-8000-000000000001',
          problemDescription: 'Não liga',
        ),
        throwsArgumentError,
      );
      expect(
        () => validateServiceOrderCreationInput(
          customerId: '10000000-0000-4000-8000-000000000001',
          equipmentId: 'eq-placeholder',
          problemDescription: 'Não liga',
        ),
        throwsArgumentError,
      );
    });

    test('rejects an empty problem description before writing the Outbox', () {
      expect(
        () => validateServiceOrderCreationInput(
          customerId: '10000000-0000-4000-8000-000000000001',
          equipmentId: '20000000-0000-4000-8000-000000000001',
          problemDescription: '   ',
        ),
        throwsArgumentError,
      );
    });

    testWidgets('submits the selected customer equipment without placeholders',
        (tester) async {
      final otherEquipment = _equipment(
        id: '20000000-0000-4000-8000-000000000002',
        customerId: '30000000-0000-4000-8000-000000000003',
      );
      final matchingEquipment = _equipment();
      await tester.pumpWidget(
        page(
          user: _admin,
          equipments: [otherEquipment, matchingEquipment],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('create_service_order_fab')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextFormField),
        'Equipamento não liga',
      );
      await tester.tap(find.byKey(const Key('create_service_order_submit')));
      await tester.pumpAndSettle();

      expect(serviceOrders.calls, hasLength(1));
      expect(serviceOrders.calls.single, {
        'customerId': '10000000-0000-4000-8000-000000000001',
        'equipmentId': '20000000-0000-4000-8000-000000000001',
        'problemDescription': 'Equipamento não liga',
        'technicianId': null,
      });
      expect(
        serviceOrders.calls.single.values,
        isNot(contains('cust-placeholder')),
      );
      expect(
        serviceOrders.calls.single.values,
        isNot(contains('eq-placeholder')),
      );
    });

    testWidgets('cannot submit without an equipment owned by the customer',
        (tester) async {
      await tester.pumpWidget(page(user: _technician, equipments: const []));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('create_service_order_fab')));
      await tester.pumpAndSettle();

      final submit = tester.widget<ElevatedButton>(
        find.byKey(const Key('create_service_order_submit')),
      );
      expect(submit.onPressed, isNull);
      expect(serviceOrders.calls, isEmpty);
    });
  });
}

CustomerEntity _customer() {
  return CustomerEntity(
    id: '10000000-0000-4000-8000-000000000001',
    name: 'Cliente',
    updatedAt: '2026-09-23T10:00:00.000Z',
  );
}

EquipmentEntity _equipment({
  String id = '20000000-0000-4000-8000-000000000001',
  String customerId = '10000000-0000-4000-8000-000000000001',
}) {
  return EquipmentEntity(
    id: id,
    customerId: customerId,
    type: 'Notebook',
    brand: 'Marca',
    model: 'Modelo',
    updatedAt: '2026-09-23T10:00:00.000Z',
  );
}
