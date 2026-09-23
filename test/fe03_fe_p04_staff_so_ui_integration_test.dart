import 'dart:async';

import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/auth/application/auth_provider.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/parts/part_entity.dart';
import 'package:assistailab/features/parts/parts_provider.dart';
import 'package:assistailab/features/service_orders/service_order_detail_page.dart';
import 'package:assistailab/features/service_orders/service_order_details_provider.dart';
import 'package:assistailab/features/service_orders/service_order_entity.dart';
import 'package:assistailab/features/service_orders/service_order_item_entity.dart';
import 'package:assistailab/features/service_orders/staff_so_commands_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _ProjectionFactory = StaffServiceOrderProjection Function(
  String command,
  Map<String, Object?> arguments,
);

final class _RecordedCommand {
  const _RecordedCommand(this.name, this.arguments);

  final String name;
  final Map<String, Object?> arguments;
}

class _MockStaffSoCommandsNotifier extends AsyncNotifier<void>
    implements StaffSoCommandsNotifier {
  final calls = <_RecordedCommand>[];
  Completer<void>? _pending;
  Object? nextError;
  StaffServiceOrderProjection? nextProjection;
  _ProjectionFactory? projectionFactory;

  @override
  Future<void> build() async {}

  void blockNext() => _pending = Completer<void>();

  void completeNext() {
    _pending?.complete();
    _pending = null;
  }

  Future<StaffServiceOrderProjection> _record(
    String command,
    Map<String, Object?> arguments,
  ) async {
    calls.add(_RecordedCommand(command, arguments));
    state = const AsyncLoading();
    try {
      final pending = _pending;
      if (pending != null) await pending.future;
      final error = nextError;
      nextError = null;
      if (error != null) throw error;

      final projection = nextProjection ??
          projectionFactory?.call(command, arguments) ??
          _projection(
            arguments['serviceOrderId']! as String,
            _resultStatus(command),
          );
      nextProjection = null;
      state = const AsyncData(null);
      return projection;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
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
    required String? diagnosis,
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

class _MockServiceOrderItemsNotifier extends ServiceOrderItemsNotifier {
  _MockServiceOrderItemsNotifier(this.items);

  final List<ServiceOrderItemEntity> items;

  @override
  Future<List<ServiceOrderItemEntity>> build(String arg) async => items;
}

class _MockPartsNotifier extends PartsNotifier {
  @override
  Future<List<PartEntity>> build() async => const [];
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
  id: 'tech-1',
  name: 'Technician',
  email: 'tech@example.com',
  role: 'TECHNICIAN',
  status: 'ACTIVE',
  organizationId: 'org-1',
);

const _customer = User(
  id: 'customer-user-1',
  name: 'Customer',
  email: 'customer@example.com',
  role: 'CUSTOMER',
  status: 'ACTIVE',
  customerId: 'customer-1',
);

void main() {
  late _MockStaffSoCommandsNotifier commands;
  var items = <ServiceOrderItemEntity>[];

  setUp(() {
    commands = _MockStaffSoCommandsNotifier();
    items = <ServiceOrderItemEntity>[];
  });

  Future<void> pumpPage(
    WidgetTester tester,
    ServiceOrderEntity order,
    User user,
  ) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(user),
          staffSoCommandsProvider.overrideWith(() => commands),
          serviceOrderItemsProvider.overrideWith(
            () => _MockServiceOrderItemsNotifier(items),
          ),
          partsProvider.overrideWith(_MockPartsNotifier.new),
        ],
        child: MaterialApp(home: ServiceOrderDetailPage(order: order)),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester, Key buttonKey) async {
    await tester.ensureVisible(find.byKey(buttonKey));
    await tester.tap(find.byKey(buttonKey));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  group('dispatch', () {
    testWidgets('publishInitialQuote forwards id and optional changeReason',
        (tester) async {
      final order = _order(ServiceOrderStatusEnum.diagnostico);
      await pumpPage(tester, order, _admin);
      await openDialog(tester, const Key('btn_publish_quote'));

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        'Publicação inicial',
      );
      await tester.tap(find.text('Publicar'));
      await tester.pumpAndSettle();

      expect(commands.calls, hasLength(1));
      expect(commands.calls.single.name, 'publishInitialQuote');
      expect(commands.calls.single.arguments, {
        'serviceOrderId': order.id,
        'changeReason': 'Publicação inicial',
      });
    });

    testWidgets('publishCommercialRevision forwards diagnosis and every item',
        (tester) async {
      final order = _order(ServiceOrderStatusEnum.emExecucao);
      items = [_item(order.id)];
      await pumpPage(tester, order, _technician);
      await openDialog(tester, const Key('btn_revise_quote'));

      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.at(0), 'Diagnóstico revisado');
      await tester.enterText(fields.at(1), 'Cliente pediu alteração');
      await tester.tap(find.text('Revisar'));
      await tester.pumpAndSettle();

      final call = commands.calls.single;
      expect(call.name, 'publishCommercialRevision');
      expect(call.arguments['serviceOrderId'], order.id);
      expect(call.arguments['diagnosis'], 'Diagnóstico revisado');
      expect(call.arguments['changeReason'], 'Cliente pediu alteração');
      final sentItems =
          call.arguments['items']! as List<StaffSoQuoteRevisionItem>;
      expect(sentItems, hasLength(1));
      expect(sentItems.single.id, 'item-1');
      expect(sentItems.single.partId, 'part-1');
      expect(sentItems.single.description, 'Peça');
      expect(sentItems.single.quantity, 2);
      expect(sentItems.single.unitPriceMinor, 1250);
    });

    testWidgets('resumeApprovedScope forwards id and reason', (tester) async {
      final order = _order(ServiceOrderStatusEnum.aguardandoReaprovacao);
      await pumpPage(tester, order, _admin);
      await openDialog(tester, const Key('btn_resume_scope'));

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        'Retomar revisão aprovada',
      );
      await tester.tap(find.text('Retomar'));
      await tester.pumpAndSettle();

      expect(commands.calls.single.name, 'resumeApprovedScope');
      expect(commands.calls.single.arguments, {
        'serviceOrderId': order.id,
        'reason': 'Retomar revisão aprovada',
      });
    });

    testWidgets('markReady preserves omitted notes', (tester) async {
      final order = _order(ServiceOrderStatusEnum.emExecucao);
      await pumpPage(tester, order, _technician);
      await openDialog(tester, const Key('btn_mark_ready'));

      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      expect(commands.calls.single.name, 'markReady');
      expect(commands.calls.single.arguments, {
        'serviceOrderId': order.id,
        'notes': null,
      });
    });

    testWidgets('markDelivered forwards id and notes', (tester) async {
      final order = _order(ServiceOrderStatusEnum.pronto);
      await pumpPage(tester, order, _admin);
      await openDialog(tester, const Key('btn_mark_delivered'));

      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        ),
        'Entregue ao responsável',
      );
      await tester.tap(find.text('Confirmar Entrega'));
      await tester.pumpAndSettle();

      expect(commands.calls.single.name, 'markDelivered');
      expect(commands.calls.single.arguments, {
        'serviceOrderId': order.id,
        'notes': 'Entregue ao responsável',
      });
    });
  });

  group('Projection v2', () {
    testWidgets('confirmed projection updates the displayed representation',
        (tester) async {
      final order = _order(ServiceOrderStatusEnum.emExecucao);
      await pumpPage(tester, order, _admin);
      await openDialog(tester, const Key('btn_mark_ready'));

      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      expect(find.text('Status: Pronto'), findsOneWidget);
      expect(find.byKey(const Key('btn_mark_delivered')), findsOneWidget);
      expect(find.text('OS marcada como Pronta.'), findsOneWidget);
    });

    for (final invalidCase in <({String name, String id, int version})>[
      (name: 'wrong contract version', id: 'os-1', version: 1),
      (name: 'different service order id', id: 'os-other', version: 2),
    ]) {
      testWidgets('${invalidCase.name} is not applied as success',
          (tester) async {
        final order = _order(ServiceOrderStatusEnum.emExecucao);
        commands.nextProjection = _projection(
          invalidCase.id,
          ServiceOrderStatusEnum.pronto,
          contractVersion: invalidCase.version,
        );
        await pumpPage(tester, order, _admin);
        await openDialog(tester, const Key('btn_mark_ready'));

        await tester.tap(find.text('Confirmar'));
        await tester.pumpAndSettle();

        expect(find.text('Status: Em execução'), findsOneWidget);
        expect(find.text('OS marcada como Pronta.'), findsNothing);
        expect(
          find.textContaining('Não foi possível confirmar o resultado'),
          findsOneWidget,
        );
      });
    }
  });

  group('errors and UNKNOWN', () {
    testWidgets('4xx is shown as a confirmed command failure', (tester) async {
      final order = _order(ServiceOrderStatusEnum.emExecucao);
      commands.nextError = const StaffSoCommandException(
        422,
        'INVALID_COMMAND',
        safeMessage: 'Comando inválido.',
      );
      await pumpPage(tester, order, _admin);
      await openDialog(tester, const Key('btn_mark_ready'));

      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      expect(find.text('Comando inválido.'), findsOneWidget);
      expect(find.text('OS marcada como Pronta.'), findsNothing);
      expect(find.text('Status: Em execução'), findsOneWidget);
    });

    for (final code in const [
      'IDEMPOTENCY_IN_PROGRESS',
      'IDEMPOTENCY_STATE_CONFLICT',
    ]) {
      testWidgets('$code remains unconfirmed', (tester) async {
        final order = _order(ServiceOrderStatusEnum.emExecucao);
        commands.nextError = StaffSoCommandException(409, code);
        await pumpPage(tester, order, _admin);
        await openDialog(tester, const Key('btn_mark_ready'));

        await tester.tap(find.text('Confirmar'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('ainda não pôde ser confirmada'),
          findsOneWidget,
        );
        expect(find.text('OS marcada como Pronta.'), findsNothing);
        expect(find.text('Status: Em execução'), findsOneWidget);
      });
    }

    testWidgets('projection uncertainty is never presented as success',
        (tester) async {
      final order = _order(ServiceOrderStatusEnum.emExecucao);
      commands.nextError = StaffSoProjectionUncertaintyException(
        cause: TimeoutException('projection timeout'),
      );
      await pumpPage(tester, order, _admin);
      await openDialog(tester, const Key('btn_mark_ready'));

      await tester.tap(find.text('Confirmar'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Não foi possível confirmar o resultado'),
        findsOneWidget,
      );
      expect(find.text('OS marcada como Pronta.'), findsNothing);
      expect(find.text('Status: Em execução'), findsOneWidget);
    });
  });

  group('authorization UI', () {
    testWidgets('CUSTOMER cannot see or execute STAFF actions', (tester) async {
      await pumpPage(
        tester,
        _order(ServiceOrderStatusEnum.diagnostico),
        _customer,
      );

      expect(find.text('Ações da OS'), findsNothing);
      expect(find.byKey(const Key('btn_publish_quote')), findsNothing);
      expect(commands.calls, isEmpty);
    });

    testWidgets('ADMIN can execute the applicable STAFF action',
        (tester) async {
      await pumpPage(
        tester,
        _order(ServiceOrderStatusEnum.diagnostico),
        _admin,
      );
      expect(find.byKey(const Key('btn_publish_quote')), findsOneWidget);
    });

    testWidgets('TECHNICIAN can execute the applicable STAFF action',
        (tester) async {
      await pumpPage(
        tester,
        _order(ServiceOrderStatusEnum.pronto),
        _technician,
      );
      expect(find.byKey(const Key('btn_mark_delivered')), findsOneWidget);
    });
  });

  testWidgets('provider loading state prevents a simultaneous second dispatch',
      (tester) async {
    final order = _order(ServiceOrderStatusEnum.emExecucao);
    commands.blockNext();
    await pumpPage(tester, order, _admin);
    await openDialog(tester, const Key('btn_mark_ready'));

    await tester.tap(find.text('Confirmar'));
    await tester.pump();

    expect(commands.calls, hasLength(1));
    expect(find.text('Processando...'), findsOneWidget);
    expect(find.byKey(const Key('btn_mark_ready')), findsNothing);

    await tester.tapAt(const Offset(30, 30));
    await tester.pump();
    expect(commands.calls, hasLength(1));

    commands.completeNext();
    await tester.pumpAndSettle();
    expect(commands.calls, hasLength(1));
  });
}

ServiceOrderStatusEnum _resultStatus(String command) => switch (command) {
      'publishInitialQuote' => ServiceOrderStatusEnum.aguardandoAprovacao,
      'publishCommercialRevision' =>
        ServiceOrderStatusEnum.aguardandoReaprovacao,
      'resumeApprovedScope' => ServiceOrderStatusEnum.emExecucao,
      'markReady' => ServiceOrderStatusEnum.pronto,
      'markDelivered' => ServiceOrderStatusEnum.entregue,
      _ => throw StateError('Unexpected test command: $command'),
    };

StaffServiceOrderProjection _projection(
  String id,
  ServiceOrderStatusEnum status, {
  int contractVersion = 2,
}) {
  return StaffServiceOrderProjection(
    serviceOrderId: id,
    wire: {
      'contractVersion': contractVersion,
      'projectionRevision': '2',
      'id': id,
      'friendlyId': 42,
      'organizationId': 'org-1',
      'customerId': 'customer-1',
      'equipmentId': 'equipment-1',
      'technicianId': 'tech-1',
      'status': status.toDbString(),
      'problemDescription': 'Não liga',
      'diagnosis': 'Fonte danificada',
      'solution': 'Troca da fonte',
      'totalAmountMinor': 2500,
      'items': const [],
      'updatedAt': '2026-09-22T12:00:00.000Z',
    },
  );
}

ServiceOrderEntity _order(ServiceOrderStatusEnum status) {
  return ServiceOrderEntity(
    id: 'os-1',
    friendlyId: 42,
    customerId: 'customer-1',
    equipmentId: 'equipment-1',
    technicianId: 'tech-1',
    status: status,
    problemDescription: 'Não liga',
    diagnosis: 'Diagnóstico inicial',
    solution: 'Solução inicial',
    totalAmount: MoneyMinor.serviceOrder(2500),
    updatedAt: '2026-09-22T10:00:00.000Z',
  );
}

ServiceOrderItemEntity _item(String serviceOrderId) {
  return ServiceOrderItemEntity(
    id: 'item-1',
    serviceOrderId: serviceOrderId,
    partId: 'part-1',
    description: 'Peça',
    quantity: 2,
    unitPrice: MoneyMinor.serviceOrder(1250),
    totalPrice: MoneyMinor.serviceOrder(2500),
    updatedAt: '2026-09-22T10:00:00.000Z',
  );
}
