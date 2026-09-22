import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/service_order_item_entity.dart';
import 'package:assistailab/features/service_orders/service_order_detail_page.dart';
import 'package:assistailab/features/service_orders/staff_so_commands_provider.dart';
import 'package:assistailab/features/service_orders/service_orders_provider.dart';
import 'package:assistailab/features/service_orders/service_order_details_provider.dart';
import 'package:assistailab/features/parts/part_entity.dart';
import 'package:assistailab/features/parts/parts_provider.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/service_orders/staff_so_command_executor.dart';
import 'package:assistailab/core/commands/command_failure.dart';
import 'dart:async';

// Sentinel fake projection returned by mock commands.
StaffServiceOrderProjection _fakeProjection(String serviceOrderId) =>
    StaffServiceOrderProjection(serviceOrderId: serviceOrderId, wire: const {});

// Mock Notifier for STAFF commands – mirrors StaffSoCommandsNotifier exactly.
class MockStaffSoCommandsNotifier extends AsyncNotifier<void>
    implements StaffSoCommandsNotifier {
  String? lastCommand;
  Map<String, dynamic>? lastArgs;
  Completer<void>? _nextCompleter;
  Object? nextError;

  void completeNext() {
    _nextCompleter?.complete();
    _nextCompleter = null;
  }

  void blockNext() {
    _nextCompleter = Completer<void>();
  }

  @override
  Future<void> build() async {}

  Future<StaffServiceOrderProjection> _record(
    String command,
    Map<String, dynamic> args,
  ) async {
    lastCommand = command;
    lastArgs = args;
    if (_nextCompleter != null) {
      await _nextCompleter!.future;
    }
    if (nextError != null) {
      final e = nextError;
      nextError = null;
      throw e!;
    }
    return _fakeProjection(args['serviceOrderId'] as String);
  }

  @override
  Future<StaffServiceOrderProjection> publishInitialQuote({
    required String serviceOrderId,
    String? changeReason,
  }) =>
      _record('publishInitialQuote', {
        'serviceOrderId': serviceOrderId,
        'changeReason': changeReason,
      });

  @override
  Future<StaffServiceOrderProjection> publishCommercialRevision({
    required String serviceOrderId,
    String? diagnosis,
    required List<StaffSoQuoteRevisionItem> items,
    required String changeReason,
  }) =>
      _record('publishCommercialRevision', {
        'serviceOrderId': serviceOrderId,
        'diagnosis': diagnosis,
        'items': items,
        'changeReason': changeReason,
      });

  @override
  Future<StaffServiceOrderProjection> resumeApprovedScope({
    required String serviceOrderId,
    required String reason,
  }) =>
      _record('resumeApprovedScope', {
        'serviceOrderId': serviceOrderId,
        'reason': reason,
      });

  @override
  Future<StaffServiceOrderProjection> markReady({
    required String serviceOrderId,
    String? notes,
  }) =>
      _record('markReady', {
        'serviceOrderId': serviceOrderId,
        'notes': notes,
      });

  @override
  Future<StaffServiceOrderProjection> markDelivered({
    required String serviceOrderId,
    String? notes,
  }) =>
      _record('markDelivered', {
        'serviceOrderId': serviceOrderId,
        'notes': notes,
      });
}

// User mocks
const _adminUser = User(
  id: 'u1',
  name: 'Admin',
  email: 'a@a.com',
  role: 'ADMIN',
  status: 'ACTIVE',
);

const _techUser = User(
  id: 'u2',
  name: 'Tech',
  email: 't@t.com',
  role: 'TECHNICIAN',
  status: 'ACTIVE',
);

const _customerUser = User(
  id: 'u3',
  name: 'Customer',
  email: 'c@c.com',
  role: 'CUSTOMER',
  status: 'ACTIVE',
);

void main() {
  late MockStaffSoCommandsNotifier mockNotifier;

  Widget createWidget(ServiceOrderEntity order, User currentUser) {
    return ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(currentUser),
        staffSoCommandsProvider.overrideWith(() => mockNotifier),
        // FamilyAsyncNotifierProvider.overrideWith: factory receives no arg at
        // the provider level; the family arg is passed via build(arg) inside.
        serviceOrderItemsProvider.overrideWith(
          () => _MockServiceOrderItemsNotifier(),
        ),
        // AutoDisposeAsyncNotifierProvider.overrideWith: factory takes no arg.
        partsProvider.overrideWith(() => _MockPartsNotifier()),
      ],
      child: MaterialApp(
        home: ServiceOrderDetailPage(order: order),
      ),
    );
  }

  setUp(() {
    mockNotifier = MockStaffSoCommandsNotifier();
  });

  group('Role Based Visibility', () {
    testWidgets('CUSTOMER does not see any STAFF actions', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.diagnostico);
      await tester.pumpWidget(createWidget(order, _customerUser));
      await tester.pumpAndSettle();

      expect(find.text('Ações da OS'), findsNothing);
      expect(find.byKey(const Key('btn_publish_quote')), findsNothing);
    });

    testWidgets('ADMIN sees publish quote in DIAGNOSTICO', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.diagnostico);
      await tester.pumpWidget(createWidget(order, _adminUser));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('btn_publish_quote')), findsOneWidget);
    });
  });

  group('Command Dispatch and Dialogs', () {
    testWidgets('publishInitialQuote dialog and dispatch', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.diagnostico);
      await tester.pumpWidget(createWidget(order, _adminUser));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_publish_quote')));
      await tester.pumpAndSettle();

      // The button label and dialog title share the same text; findsAtLeastNWidgets(1)
      // is correct here since the dialog is open alongside the button.
      expect(find.text('Publicar Orçamento'), findsAtLeastNWidgets(1));

      await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextFormField),
          ),
          'Motivo de teste');
      await tester.tap(find.text('Publicar'));
      await tester.pump();

      expect(mockNotifier.lastCommand, equals('publishInitialQuote'));
      expect(mockNotifier.lastArgs!['serviceOrderId'], equals(order.id));
      expect(mockNotifier.lastArgs!['changeReason'], equals('Motivo de teste'));

      // Success snackbar
      await tester.pumpAndSettle();
      expect(find.text('Orçamento publicado com sucesso.'), findsOneWidget);
    });

    testWidgets('markReady dialog and dispatch', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.emExecucao);
      await tester.pumpWidget(createWidget(order, _techUser));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_mark_ready')));
      await tester.pumpAndSettle();

      // Button label and dialog title share the same text.
      expect(find.text('Marcar como Pronto'), findsAtLeastNWidgets(1));

      await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextFormField),
          ),
          'Notas do pronto');
      await tester.tap(find.text('Confirmar'));
      await tester.pump();

      expect(mockNotifier.lastCommand, equals('markReady'));
      expect(mockNotifier.lastArgs!['notes'], equals('Notas do pronto'));
    });
  });

  group('Error and Uncertainty Handling', () {
    testWidgets('Uncertainty shows specific snackbar', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.emExecucao);
      mockNotifier.nextError = StaffSoProjectionUncertaintyException(
        cause: Exception('Failed to get projection'),
      );

      await tester.pumpWidget(createWidget(order, _techUser));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_mark_ready')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmar'));
      await tester.pump();

      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível confirmar o resultado'),
          findsOneWidget);
    });

    testWidgets('Standard error shows generic snackbar', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.emExecucao);
      // Use a plain Exception (not StaffSoCommandException) so the production code
      // falls into the else-branch and shows the generic fallback message.
      mockNotifier.nextError = Exception('network error');

      await tester.pumpWidget(createWidget(order, _techUser));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_mark_ready')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmar'));
      await tester.pump();

      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível executar a operação'),
          findsOneWidget);
    });
  });

  group('Concurrency', () {
    testWidgets('Prevents double tap while command in flight', (tester) async {
      final order = _createOrder(ServiceOrderStatusEnum.emExecucao);
      mockNotifier.blockNext();

      await tester.pumpWidget(createWidget(order, _adminUser));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('btn_mark_ready')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirmar'));
      await tester.pump();

      // UI should show loading
      expect(find.text('Processando...'), findsOneWidget);

      // Buttons should be gone (replaced by loading indicator)
      expect(find.byKey(const Key('btn_mark_ready')), findsNothing);

      mockNotifier.completeNext();
      await tester.pumpAndSettle();

      // Button is back
      expect(find.byKey(const Key('btn_mark_ready')), findsOneWidget);
    });
  });
}

ServiceOrderEntity _createOrder(ServiceOrderStatusEnum status) {
  return ServiceOrderEntity(
    id: 'os-1',
    customerId: 'cust-1',
    equipmentId: 'eq-1',
    status: status,
    problemDescription: 'Desc',
    updatedAt: DateTime.now().toIso8601String(),
  );
}

// Extends the concrete notifier so that overrideWith's type-check passes.
// ServiceOrderItemsNotifier extends FamilyAsyncNotifier<List<ServiceOrderItemEntity>, String>.
class _MockServiceOrderItemsNotifier extends ServiceOrderItemsNotifier {
  @override
  Future<List<ServiceOrderItemEntity>> build(String arg) async {
    return [];
  }
}

// Extends the concrete notifier so that overrideWith's type-check passes.
// PartsNotifier extends AutoDisposeAsyncNotifier<List<PartEntity>>.
class _MockPartsNotifier extends PartsNotifier {
  @override
  Future<List<PartEntity>> build() async {
    return [];
  }
}
