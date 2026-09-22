import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/money/money_minor.dart';
import 'service_order_entity.dart';
import 'service_order_item_entity.dart';
import 'service_order_details_provider.dart';
import '../parts/parts_provider.dart';

import '../auth/application/auth_provider.dart';
import 'printing/service_order_pdf_preview_page.dart';

import 'printing/service_order_print_data_provider.dart';
import 'printing/service_order_print_service.dart';
import 'staff_so_commands_provider.dart';
import 'service_orders_provider.dart';

class ServiceOrderDetailPage extends ConsumerStatefulWidget {
  final ServiceOrderEntity order;
  const ServiceOrderDetailPage({super.key, required this.order});

  @override
  ConsumerState<ServiceOrderDetailPage> createState() =>
      _ServiceOrderDetailPageState();
}

class _ServiceOrderDetailPageState
    extends ConsumerState<ServiceOrderDetailPage> {
  late TextEditingController _diagnosisController;
  late TextEditingController _solutionController;

  /// Local display entity — starts as widget.order and is updated after a
  /// successful STAFF command (re-read from the local DB after projection
  /// is applied by SyncProjectionApplier). Never mutated optimistically.
  late ServiceOrderEntity _displayOrder;

  /// Prevents concurrent STAFF command dispatches from the same page instance.
  bool _isCommandInFlight = false;

  @override
  void initState() {
    super.initState();
    _displayOrder = widget.order;
    _diagnosisController =
        TextEditingController(text: widget.order.diagnosis ?? '');
    _solutionController =
        TextEditingController(text: widget.order.solution ?? '');
  }

  @override
  void dispose() {
    _diagnosisController.dispose();
    _solutionController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Post-command entity refresh (reads from local DB — never from wire)
  // ---------------------------------------------------------------------------

  Future<void> _refreshDisplayOrderFromDb() async {
    try {
      final repo = ref.read(serviceOrderRepositoryProvider);
      final sessionKey = ref.read(authenticatedSessionKeyProvider);
      if (sessionKey == null) return;

      // Re-read the entity that SyncProjectionApplier just wrote.
      final manager =
          ref.read(staffSoDatabaseManagerProvider);
      final handle = manager.currentHandle;
      if (handle == null) return;

      final updated = await repo.findById(
        _displayOrder.id,
        executor: handle.database,
      );
      if (updated != null && mounted) {
        setState(() => _displayOrder = updated);
      }
    } catch (_) {
      // Best-effort — the UI will show stale data until the user navigates
      // away and returns, at which point serviceOrdersProvider is already
      // invalidated and will provide the authoritative entity.
    }
  }

  // ---------------------------------------------------------------------------
  // Feedback helpers
  // ---------------------------------------------------------------------------

  void _showSuccessSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showUncertaintySnackBar(StaffSoProjectionUncertaintyException e) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          e.message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: const Color(0xFFB45309),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: 'OK',
          textColor: Colors.white,
          onPressed: () =>
              ScaffoldMessenger.of(context).hideCurrentSnackBar(),
        ),
      ),
    );
  }

  void _showErrorSnackBar(Object error) {
    if (!mounted) return;
    final message = error is StaffSoCommandException
        ? error.message
        : 'Não foi possível executar a operação. Tente novamente.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Common command execution wrapper
  // ---------------------------------------------------------------------------

  Future<void> _runCommand(
    Future<StaffServiceOrderProjection> Function() command,
    String successMessage,
  ) async {
    if (_isCommandInFlight) return;
    setState(() => _isCommandInFlight = true);
    try {
      await command();
      // serviceOrdersProvider already invalidated by staffSoCommandsProvider.
      // Re-read the entity from the now-updated local DB.
      await _refreshDisplayOrderFromDb();
      _showSuccessSnackBar(successMessage);
    } on StaffSoProjectionUncertaintyException catch (e) {
      // POST succeeded but projection could not be confirmed.
      // Do NOT show success. Do NOT update status locally.
      _showUncertaintySnackBar(e);
    } catch (e) {
      _showErrorSnackBar(e);
    } finally {
      if (mounted) setState(() => _isCommandInFlight = false);
    }
  }

  // ---------------------------------------------------------------------------
  // STAFF Command 1 — Publicar Orçamento
  // ---------------------------------------------------------------------------

  Future<void> _showPublishQuoteDialog() async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Publicar Orçamento',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Esta ação enviará o orçamento ao cliente.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: reasonController,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('Motivo da publicação (opcional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0284C7)),
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Publicar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final reason = reasonController.text.trim().isEmpty
        ? null
        : reasonController.text.trim();

    await _runCommand(
      () => ref.read(staffSoCommandsProvider.notifier).publishInitialQuote(
            serviceOrderId: _displayOrder.id,
            changeReason: reason,
          ),
      'Orçamento publicado com sucesso.',
    );
  }

  // ---------------------------------------------------------------------------
  // STAFF Command 2 — Revisar Orçamento
  // ---------------------------------------------------------------------------

  Future<void> _showReviseQuoteDialog(
      List<ServiceOrderItemEntity> currentItems) async {
    final reasonController = TextEditingController();
    final diagnosisController =
        TextEditingController(text: _displayOrder.diagnosis ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Revisar Orçamento',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Revise o orçamento com os itens atuais da OS.',
                style: TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: diagnosisController,
                maxLines: 3,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Diagnóstico (opcional)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: reasonController,
                maxLines: 2,
                style: const TextStyle(color: Colors.white),
                decoration: _inputDecoration('Motivo da revisão *'),
              ),
              const SizedBox(height: 8),
              Text(
                '${currentItems.length} item(s) serão incluídos.',
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revisar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final reason = reasonController.text.trim();
    if (reason.isEmpty) {
      _showErrorSnackBar(
        ArgumentError('O motivo da revisão é obrigatório.'),
      );
      return;
    }

    final revisionItems = currentItems
        .map(
          (item) => StaffSoQuoteRevisionItem(
            id: item.id,
            partId: item.partId,
            description: item.description,
            quantity: item.quantity,
            unitPriceMinor: item.unitPrice.minorUnits,
          ),
        )
        .toList(growable: false);

    final diagnosis = diagnosisController.text.trim().isEmpty
        ? null
        : diagnosisController.text.trim();

    await _runCommand(
      () => ref
          .read(staffSoCommandsProvider.notifier)
          .publishCommercialRevision(
            serviceOrderId: _displayOrder.id,
            diagnosis: diagnosis,
            items: revisionItems,
            changeReason: reason,
          ),
      'Revisão de orçamento publicada com sucesso.',
    );
  }

  // ---------------------------------------------------------------------------
  // STAFF Command 3 — Retomar Escopo Aprovado
  // ---------------------------------------------------------------------------

  Future<void> _showResumeApprovedScopeDialog() async {
    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Retomar Escopo Aprovado',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Esta ação retoma a execução com o escopo previamente aprovado.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: reasonController,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('Motivo da retomada *'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0284C7)),
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Retomar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final reason = reasonController.text.trim();
    if (reason.isEmpty) {
      _showErrorSnackBar(
        ArgumentError('O motivo da retomada é obrigatório.'),
      );
      return;
    }

    await _runCommand(
      () => ref.read(staffSoCommandsProvider.notifier).resumeApprovedScope(
            serviceOrderId: _displayOrder.id,
            reason: reason,
          ),
      'Escopo aprovado retomado com sucesso.',
    );
  }

  // ---------------------------------------------------------------------------
  // STAFF Command 4 — Marcar como Pronto
  // ---------------------------------------------------------------------------

  Future<void> _showMarkReadyDialog() async {
    final notesController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Marcar como Pronto',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'A OS será marcada como pronta para retirada.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: notesController,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('Observações (opcional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmar',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final notes = notesController.text.trim().isEmpty
        ? null
        : notesController.text.trim();

    await _runCommand(
      () => ref.read(staffSoCommandsProvider.notifier).markReady(
            serviceOrderId: _displayOrder.id,
            notes: notes,
          ),
      'OS marcada como Pronta.',
    );
  }

  // ---------------------------------------------------------------------------
  // STAFF Command 5 — Marcar como Entregue
  // ---------------------------------------------------------------------------

  Future<void> _showMarkDeliveredDialog() async {
    final notesController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Marcar como Entregue',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Confirma que o equipamento foi entregue ao cliente?',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: notesController,
              maxLines: 2,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('Observações (opcional)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmar Entrega',
                style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    final notes = notesController.text.trim().isEmpty
        ? null
        : notesController.text.trim();

    await _runCommand(
      () => ref.read(staffSoCommandsProvider.notifier).markDelivered(
            serviceOrderId: _displayOrder.id,
            notes: notes,
          ),
      'OS marcada como Entregue.',
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(currentUserProvider);
    final role = currentUser?.role.trim().toUpperCase();
    final isStaff = role == 'ADMIN' || role == 'TECHNICIAN';
    final canPrint = isStaff;

    final itemsAsync = ref.watch(serviceOrderItemsProvider(_displayOrder.id));
    final partsAsync = ref.watch(partsProvider);

    final status = _displayOrder.status;

    // Determine which STAFF actions are visible for the current status.
    // These are UX-only rules — the backend is the security authority.
    final showPublishQuote = isStaff && status == ServiceOrderStatusEnum.diagnostico;
    final showReviseQuote = isStaff &&
        (status == ServiceOrderStatusEnum.aguardandoAprovacao ||
            status == ServiceOrderStatusEnum.aguardandoReaprovacao);
    final showResumeApprovedScope =
        isStaff && status == ServiceOrderStatusEnum.aguardandoReaprovacao;
    final showMarkReady =
        isStaff && status == ServiceOrderStatusEnum.emExecucao;
    final showMarkDelivered =
        isStaff && status == ServiceOrderStatusEnum.pronto;

    final hasAnyStaffAction = showPublishQuote ||
        showReviseQuote ||
        showResumeApprovedScope ||
        showMarkReady ||
        showMarkDelivered;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: Text(
          'Detalhes da OS #${_displayOrder.friendlyId ?? '—'}',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        actions: [
          if (canPrint)
            PopupMenuButton<String>(
              tooltip: 'Documento da OS',
              icon: const Icon(
                Icons.print_outlined,
                color: Colors.white,
              ),
              onSelected: (value) async {
                switch (value) {
                  case 'preview':
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (context) => ServiceOrderPdfPreviewPage(
                          order: _displayOrder,
                        ),
                      ),
                    );
                    break;

                  case 'print':
                    await _printServiceOrder();
                    break;
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem<String>(
                  value: 'preview',
                  child: Row(
                    children: [
                      Icon(
                        Icons.picture_as_pdf_outlined,
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Visualizar PDF',
                      ),
                    ],
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'print',
                  child: Row(
                    children: [
                      Icon(
                        Icons.print_outlined,
                      ),
                      SizedBox(width: 12),
                      Text(
                        'Imprimir OS',
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status & Summary Card
            Card(
              color: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Status: ${_displayOrder.status.label}',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                        Text(
                          'Total: ${formatMoneyMinor(_displayOrder.totalAmount)}',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4ADE80),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('Descrição do Problema:',
                        style: TextStyle(color: Colors.white54, fontSize: 13)),
                    const SizedBox(height: 4),
                    Text(_displayOrder.problemDescription,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // ── STAFF Actions Card ──────────────────────────────────────────
            if (hasAnyStaffAction) ...[
              Card(
                color: const Color(0xFF1E293B),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Color(0xFF334155)),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.manage_accounts_outlined,
                              color: Color(0xFF38BDF8), size: 20),
                          SizedBox(width: 8),
                          Text(
                            'Ações da OS',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_isCommandInFlight) ...[
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF38BDF8),
                                  ),
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'Processando...',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ] else ...[
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (showPublishQuote)
                              _StaffActionButton(
                                key: const Key('btn_publish_quote'),
                                label: 'Publicar Orçamento',
                                icon: Icons.send_outlined,
                                color: const Color(0xFF0284C7),
                                onPressed: _showPublishQuoteDialog,
                              ),
                            if (showReviseQuote)
                              _StaffActionButton(
                                key: const Key('btn_revise_quote'),
                                label: 'Revisar Orçamento',
                                icon: Icons.edit_outlined,
                                color: const Color(0xFF7C3AED),
                                onPressed: () => itemsAsync.whenData(
                                  (items) => _showReviseQuoteDialog(items),
                                ),
                              ),
                            if (showResumeApprovedScope)
                              _StaffActionButton(
                                key: const Key('btn_resume_scope'),
                                label: 'Retomar Escopo',
                                icon: Icons.play_circle_outline,
                                color: const Color(0xFF0284C7),
                                onPressed: _showResumeApprovedScopeDialog,
                              ),
                            if (showMarkReady)
                              _StaffActionButton(
                                key: const Key('btn_mark_ready'),
                                label: 'Marcar como Pronto',
                                icon: Icons.check_circle_outline,
                                color: const Color(0xFF16A34A),
                                onPressed: _showMarkReadyDialog,
                              ),
                            if (showMarkDelivered)
                              _StaffActionButton(
                                key: const Key('btn_mark_delivered'),
                                label: 'Marcar como Entregue',
                                icon: Icons.handshake_outlined,
                                color: const Color(0xFF16A34A),
                                onPressed: _showMarkDeliveredDialog,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Technical Diagnosis & Solution Section
            Card(
              color: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF334155)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.assignment,
                            color: Color(0xFF38BDF8), size: 20),
                        SizedBox(width: 8),
                        Text(
                          'Laudo Técnico & Solução',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _diagnosisController,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Diagnóstico Técnico'),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _solutionController,
                      maxLines: 2,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Solução Aplicada'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Items (Parts & Services) Section
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(Icons.build, color: Color(0xFF38BDF8), size: 20),
                    SizedBox(width: 8),
                    Text(
                      'Peças & Mão de Obra',
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.white),
                    ),
                  ],
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7)),
                  icon: const Icon(Icons.add, color: Colors.white, size: 18),
                  label: const Text('Adicionar Item',
                      style: TextStyle(color: Colors.white)),
                  onPressed: () =>
                      _showAddItemDialog(context, partsAsync.value ?? []),
                ),
              ],
            ),
            const SizedBox(height: 12),

            itemsAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: Color(0xFF38BDF8))),
              error: (err, _) => Text('Erro ao carregar itens: $err',
                  style: const TextStyle(color: Colors.redAccent)),
              data: (items) {
                if (items.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: const Center(
                      child: Text(
                        'Nenhuma peça ou serviço adicionado a esta OS ainda.',
                        style: TextStyle(color: Colors.white54),
                      ),
                    ),
                  );
                }

                return Column(
                  children: items
                      .map((item) =>
                          _ItemTile(item: item, orderId: _displayOrder.id))
                      .toList(),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _printServiceOrder() async {
    try {
      final printData = await ref.read(
        serviceOrderPrintDataProvider(
          _displayOrder,
        ).future,
      );

      final result = await ServiceOrderPrintService.print(
        printData,
      );

      if (!mounted) {
        return;
      }

      if (!result) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'A impressão foi cancelada.',
            ),
          ),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Não foi possível imprimir a OS: $error',
          ),
        ),
      );
    }
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF334155)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: Color(0xFF38BDF8)),
      ),
      filled: true,
      fillColor: const Color(0xFF0F172A),
    );
  }

  void _showAddItemDialog(BuildContext context, List<dynamic> availableParts) {
    final descController = TextEditingController();
    final qtyController = TextEditingController(text: '1');
    final priceController = TextEditingController(text: '0.00');
    String? selectedPartId;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E293B),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text(
              'Adicionar Peça / Serviço',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (availableParts.isNotEmpty) ...[
                    DropdownButtonFormField<String>(
                      value: selectedPartId,
                      dropdownColor: const Color(0xFF1E293B),
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Selecionar do Estoque'),
                      items: availableParts.map<DropdownMenuItem<String>>((p) {
                        return DropdownMenuItem<String>(
                          value: p.id as String,
                          child: Text(
                              '${p.name} (${formatMoneyMinor(p.price)})',
                              style: const TextStyle(color: Colors.white)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        final found = availableParts
                            .firstWhere((p) => p.id == val, orElse: () => null);
                        if (found != null) {
                          setState(() {
                            selectedPartId = val;
                            descController.text = found.name;
                            priceController.text =
                                formatMoneyMinorForInput(found.price);
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextFormField(
                    controller: descController,
                    style: const TextStyle(color: Colors.white),
                    decoration:
                        _inputDecoration('Descrição (Peça ou Serviço) *'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: qtyController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Qtd *'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: priceController,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          style: const TextStyle(color: Colors.white),
                          decoration: _inputDecoration('Valor Unit. (R\$) *'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar',
                    style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7)),
                onPressed: () async {
                  if (descController.text.trim().isEmpty) return;
                  final qty = int.tryParse(qtyController.text.trim()) ?? 1;
                  MoneyMinor price;
                  try {
                    price = parseMoneyInput(
                      priceController.text,
                      maximum: MoneyMinor.serviceOrderMaximum,
                    );
                  } catch (_) {
                    return;
                  }

                  await ref
                      .read(serviceOrderItemsProvider(_displayOrder.id)
                          .notifier)
                      .addItem(
                        serviceOrderId: _displayOrder.id,
                        partId: selectedPartId,
                        description: descController.text.trim(),
                        quantity: qty,
                        unitPrice: price,
                      );
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: const Text('Adicionar',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// STAFF Action Button widget
// ---------------------------------------------------------------------------

class _StaffActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  const _StaffActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      onPressed: onPressed,
    );
  }
}

// ---------------------------------------------------------------------------
// Item Tile
// ---------------------------------------------------------------------------

class _ItemTile extends ConsumerWidget {
  final ServiceOrderItemEntity item;
  final String orderId;
  const _ItemTile({required this.item, required this.orderId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      color: const Color(0xFF1E293B),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xFF334155)),
      ),
      child: ListTile(
        title: Text(item.description,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        subtitle: Text(
          '${item.quantity}x  ${formatMoneyMinor(item.unitPrice)}',
          style: const TextStyle(color: Colors.white70),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              formatMoneyMinor(item.totalPrice),
              style: const TextStyle(
                  color: Color(0xFF4ADE80),
                  fontWeight: FontWeight.bold,
                  fontSize: 15),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.redAccent, size: 20),
              onPressed: () {
                ref
                    .read(serviceOrderItemsProvider(orderId).notifier)
                    .deleteItem(item.id, orderId);
              },
            ),
          ],
        ),
      ),
    );
  }
}
