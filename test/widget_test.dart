import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:assistailab/app_module.dart';
import 'package:assistailab/app_widget.dart';

void main() {
  testWidgets('App initialization smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: ModularApp(
          module: AppModule(),
          child: const AppWidget(),
        ),
      ),
    );

    expect(find.text('AssistAILab'), findsNothing);
  });
}
