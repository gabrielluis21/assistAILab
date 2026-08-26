import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../service_order_entity.dart';
import 'service_order_pdf_builder.dart';
import 'service_order_print_data_provider.dart';

class ServiceOrderPdfPreviewPage extends ConsumerWidget {
  const ServiceOrderPdfPreviewPage({
    super.key,
    required this.order,
  });

  final ServiceOrderEntity order;

  @override
  Widget build(
    BuildContext context,
    WidgetRef ref,
  ) {
    final printDataAsync = ref.watch(
      serviceOrderPrintDataProvider(
        order,
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'OS #${order.friendlyId ?? '-'}',
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
                if (value == 'preview') {
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => ServiceOrderPdfPreviewPage(
                        order: widget.order,
                      ),
                    ),
                  );

                  return;
                }

                if (value == 'print') {
                  await _printServiceOrder();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(
                  value: 'preview',
                  child: ListTile(
                    leading: Icon(
                      Icons.picture_as_pdf_outlined,
                    ),
                    title: Text(
                      'Visualizar PDF',
                    ),
                  ),
                ),
                PopupMenuItem(
                  value: 'print',
                  child: ListTile(
                    leading: Icon(
                      Icons.print_outlined,
                    ),
                    title: Text(
                      'Imprimir OS',
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: printDataAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(),
        ),
        error: (error, stackTrace) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(
                24,
              ),
              child: Text(
                'Não foi possível preparar a OS para impressão.\n\n$error',
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
        data: (printData) {
          return PdfPreview(
            canChangeOrientation: false,
            canChangePageFormat: false,
            allowPrinting: true,
            allowSharing: false,
            pdfFileName: 'OS_${order.friendlyId ?? order.id}.pdf',
            build: (format) {
              return ServiceOrderPdfBuilder.build(
                printData,
              );
            },
          );
        },
      ),
    );
  }
}
