import 'package:printing/printing.dart';

import 'service_order_pdf_builder.dart';
import 'service_order_print_data.dart';

abstract final class ServiceOrderPrintService {
  static Future<bool> print(
    ServiceOrderPrintData data,
  ) {
    return Printing.layoutPdf(
      name:
          'OS_${data.order.friendlyId ?? data.order.id}',
      dynamicLayout: false,
      onLayout: (format) {
        return ServiceOrderPdfBuilder.build(
          data,
        );
      },
    );
  }
}