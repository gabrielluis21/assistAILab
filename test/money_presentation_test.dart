import 'package:assistailab/core/money/money_minor.dart';
import 'package:assistailab/features/customer_portal/presentation/customer_service_order_detail_page.dart'
    as customer_detail;
import 'package:assistailab/features/customer_portal/presentation/customer_service_orders_page.dart'
    as customer_list;
import 'package:assistailab/features/service_orders/printing/service_order_pdf_builder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('staff, CUSTOMER and PDF surfaces format directly from minor units', () {
    final value = MoneyMinor(123456);

    expect(formatMoneyMinor(value), r'R$ 1.234,56');
    expect(
      customer_list.formatCustomerServiceOrderCurrency(value),
      r'R$ 1.234,56',
    );
    expect(
      customer_detail.formatCustomerServiceOrderCurrency(value),
      r'R$ 1.234,56',
    );
    expect(
      ServiceOrderPdfBuilder.formatMoneyForPdf(value),
      r'R$ 1.234,56',
    );
  });
}
