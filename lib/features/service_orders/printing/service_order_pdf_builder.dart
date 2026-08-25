import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../service_order_entity.dart';
import 'service_order_print_data.dart';

abstract final class ServiceOrderPdfBuilder {
  static Future<Uint8List> build(
    ServiceOrderPrintData data,
  ) async {
    final pdf = pw.Document(
      title: 'Ordem de Serviço #${data.order.friendlyId ?? data.order.id}',
      author: 'AssistAILab',
      creator: 'AssistAILab',
    );

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (context) => _header(data),
        footer: (context) => _footer(context),
        build: (context) => [
          _customerSection(data),
          pw.SizedBox(height: 12),
          _equipmentSection(data),
          pw.SizedBox(height: 12),
          _textSection(
            'PROBLEMA RELATADO',
            data.order.problemDescription,
          ),
          pw.SizedBox(height: 12),
          _textSection(
            'DIAGNÓSTICO TÉCNICO',
            _nullableText(
              data.order.diagnosis,
            ),
          ),
          pw.SizedBox(height: 12),
          _textSection(
            'SOLUÇÃO',
            _nullableText(
              data.order.solution,
            ),
          ),
          pw.SizedBox(height: 12),
          _itemsSection(data),
          pw.SizedBox(height: 16),
          _totalSection(data),
          pw.SizedBox(height: 16),
          _statusSection(data),
          if (data.consultationQrPayload != null ||
              data.onboardingQrPayload != null) ...[
            pw.SizedBox(height: 20),
            _qrSection(data),
          ],
        ],
      ),
    );

    return pdf.save();
  }

  static pw.Widget _header(
    ServiceOrderPrintData data,
  ) {
    return pw.Container(
      padding: const pw.EdgeInsets.only(
        bottom: 16,
      ),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(
            color: PdfColors.grey400,
            width: 1,
          ),
        ),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'AssistAILab',
                  style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue800,
                  ),
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Assistência Técnica',
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
              ],
            ),
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                'ORDEM DE SERVIÇO',
                style: pw.TextStyle(
                  fontSize: 15,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                '#${data.order.friendlyId ?? '-'}',
                style: pw.TextStyle(
                  fontSize: 19,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.blue800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _customerSection(
    ServiceOrderPrintData data,
  ) {
    final customer = data.customer;

    return _section(
      title: 'CLIENTE',
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          _field(
            'Nome',
            customer?.name ?? 'Não disponível localmente',
          ),
          pw.SizedBox(height: 5),
          pw.Row(
            children: [
              pw.Expanded(
                child: _field(
                  'Telefone',
                  _optional(
                    customer?.phone,
                  ),
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: _field(
                  'E-mail',
                  _optional(
                    customer?.email,
                  ),
                ),
              ),
            ],
          ),
          if (_hasText(
            customer?.document,
          )) ...[
            pw.SizedBox(height: 5),
            _field(
              'Documento',
              customer!.document!,
            ),
          ],
          if (_hasText(
            customer?.address,
          )) ...[
            pw.SizedBox(height: 5),
            _field(
              'Endereço',
              customer!.address!,
            ),
          ],
        ],
      ),
    );
  }

  static pw.Widget _equipmentSection(
    ServiceOrderPrintData data,
  ) {
    final equipment = data.equipment;

    return _section(
      title: 'EQUIPAMENTO',
      child: pw.Column(
        children: [
          pw.Row(
            children: [
              pw.Expanded(
                child: _field(
                  'Tipo',
                  equipment?.type ?? '-',
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: _field(
                  'Marca',
                  equipment?.brand ?? '-',
                ),
              ),
              pw.SizedBox(width: 12),
              pw.Expanded(
                child: _field(
                  'Modelo',
                  equipment?.model ?? '-',
                ),
              ),
            ],
          ),
          if (_hasText(
            equipment?.serialNumber,
          )) ...[
            pw.SizedBox(height: 5),
            _field(
              'Número de série',
              equipment!.serialNumber!,
            ),
          ],
          if (_hasText(
            equipment?.notes,
          )) ...[
            pw.SizedBox(height: 5),
            _field(
              'Observações',
              equipment!.notes!,
            ),
          ],
        ],
      ),
    );
  }

  static pw.Widget _textSection(
    String title,
    String value,
  ) {
    return _section(
      title: title,
      child: pw.Text(
        value,
        style: const pw.TextStyle(
          fontSize: 10,
          lineSpacing: 3,
        ),
      ),
    );
  }

  static pw.Widget _itemsSection(
    ServiceOrderPrintData data,
  ) {
    if (data.items.isEmpty) {
      return _section(
        title: 'PEÇAS E SERVIÇOS',
        child: pw.Text(
          'Nenhum item registrado.',
          style: const pw.TextStyle(
            fontSize: 10,
            color: PdfColors.grey700,
          ),
        ),
      );
    }

    return _section(
      title: 'PEÇAS E SERVIÇOS',
      child: pw.Table(
        border: pw.TableBorder.all(
          color: PdfColors.grey300,
          width: 0.5,
        ),
        columnWidths: const {
          0: pw.FlexColumnWidth(4),
          1: pw.FlexColumnWidth(1),
          2: pw.FlexColumnWidth(1.5),
          3: pw.FlexColumnWidth(1.5),
        },
        children: [
          _tableRow(
            [
              'Descrição',
              'Qtd.',
              'Unitário',
              'Total',
            ],
            header: true,
          ),
          ...data.items.map(
            (item) => _tableRow(
              [
                item.description,
                item.quantity.toString(),
                _money(item.unitPrice),
                _money(item.totalPrice),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static pw.TableRow _tableRow(
    List<String> values, {
    bool header = false,
  }) {
    return pw.TableRow(
      decoration: header
          ? const pw.BoxDecoration(
              color: PdfColors.grey200,
            )
          : null,
      children: values
          .map(
            (value) => pw.Padding(
              padding: const pw.EdgeInsets.all(
                6,
              ),
              child: pw.Text(
                value,
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight:
                      header ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  static pw.Widget _totalSection(
    ServiceOrderPrintData data,
  ) {
    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Container(
        width: 220,
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: PdfColors.blue50,
          border: pw.Border.all(
            color: PdfColors.blue200,
          ),
          borderRadius: pw.BorderRadius.circular(4),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              'TOTAL',
              style: pw.TextStyle(
                fontSize: 11,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
            pw.Text(
              _money(
                data.order.totalAmount,
              ),
              style: pw.TextStyle(
                fontSize: 14,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blue800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static pw.Widget _statusSection(
    ServiceOrderPrintData data,
  ) {
    return _section(
      title: 'INFORMAÇÕES DA OS',
      child: pw.Row(
        children: [
          pw.Expanded(
            child: _field(
              'Status',
              _statusLabel(
                data.order.status,
              ),
            ),
          ),
          pw.SizedBox(width: 12),
          pw.Expanded(
            child: _field(
              'Última atualização',
              _formatDate(
                data.order.updatedAt,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _qrSection(
    ServiceOrderPrintData data,
  ) {
    return _section(
      title: 'ACESSO DIGITAL',
      child: pw.Row(
        children: [
          if (data.consultationQrPayload != null)
            pw.Column(
              children: [
                pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: data.consultationQrPayload!,
                  width: 80,
                  height: 80,
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Consultar OS',
                  style: const pw.TextStyle(
                    fontSize: 8,
                  ),
                ),
              ],
            ),
          if (data.consultationQrPayload != null &&
              data.onboardingQrPayload != null)
            pw.SizedBox(width: 30),
          if (data.onboardingQrPayload != null)
            pw.Column(
              children: [
                pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: data.onboardingQrPayload!,
                  width: 80,
                  height: 80,
                ),
                pw.SizedBox(height: 4),
                pw.Text(
                  'Primeiro acesso',
                  style: const pw.TextStyle(
                    fontSize: 8,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  static pw.Widget _section({
    required String title,
    required pw.Widget child,
  }) {
    return pw.Container(
      width: double.infinity,
      decoration: pw.BoxDecoration(
        border: pw.Border.all(
          color: PdfColors.grey300,
          width: 0.8,
        ),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 7,
            ),
            color: PdfColors.grey200,
            child: pw.Text(
              title,
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
          pw.Padding(
            padding: const pw.EdgeInsets.all(10),
            child: child,
          ),
        ],
      ),
    );
  }

  static pw.Widget _field(
    String label,
    String value,
  ) {
    return pw.RichText(
      text: pw.TextSpan(
        children: [
          pw.TextSpan(
            text: '$label: ',
            style: pw.TextStyle(
              fontSize: 9,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.grey700,
            ),
          ),
          pw.TextSpan(
            text: value,
            style: const pw.TextStyle(
              fontSize: 9,
              color: PdfColors.black,
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _footer(
    pw.Context context,
  ) {
    return pw.Container(
      alignment: pw.Alignment.center,
      margin: const pw.EdgeInsets.only(
        top: 12,
      ),
      child: pw.Text(
        'AssistAILab • Página '
        '${context.pageNumber} de '
        '${context.pagesCount}',
        style: const pw.TextStyle(
          fontSize: 8,
          color: PdfColors.grey600,
        ),
      ),
    );
  }

  static String _money(
    double value,
  ) {
    return 'R\$ '
        '${value.toStringAsFixed(2).replaceAll('.', ',')}';
  }

  static String _nullableText(
    String? value,
  ) {
    if (!_hasText(value)) {
      return 'Não informado.';
    }

    return value!.trim();
  }

  static String _optional(
    String? value,
  ) {
    if (!_hasText(value)) {
      return '-';
    }

    return value!.trim();
  }

  static bool _hasText(
    String? value,
  ) {
    return value != null && value.trim().isNotEmpty;
  }

  static String _statusLabel(
    ServiceOrderStatusEnum status,
  ) {
    switch (status) {
      case ServiceOrderStatusEnum.draft:
        return 'Rascunho';

      case ServiceOrderStatusEnum.diagnostico:
        return 'Em diagnóstico';

      case ServiceOrderStatusEnum.aguardandoAprovacao:
        return 'Aguardando aprovação';

      case ServiceOrderStatusEnum.emExecucao:
        return 'Em execução';

      case ServiceOrderStatusEnum.pronto:
        return 'Pronto';

      case ServiceOrderStatusEnum.entregue:
        return 'Entregue';

      case ServiceOrderStatusEnum.cancelado:
        return 'Cancelado';
    }
  }

  static String _formatDate(
    String value,
  ) {
    final parsed = DateTime.tryParse(value);

    if (parsed == null) {
      return value;
    }

    final local = parsed.toLocal();

    final day = local.day.toString().padLeft(2, '0');
    final month = local.month.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');

    return '$day/$month/${local.year} '
        '$hour:$minute';
  }
}
