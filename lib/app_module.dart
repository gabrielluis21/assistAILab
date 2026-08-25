import 'package:flutter_modular/flutter_modular.dart';

import 'core/presentation/app_shell.dart';
import 'core/presentation/auth_guard_page.dart';
import 'features/auth/presentation/login_page.dart';
import 'features/customer_portal/presentation/customer_shell.dart';

class AppModule extends Module {
  @override
  void binds(Injector i) {}

  @override
  void routes(RouteManager r) {
    r.child(
      '/',
      child: (context) => const AuthGuardPage(),
    );

    r.child(
      '/login',
      child: (context) => const LoginPage(),
    );

    r.child(
      '/home',
      child: (context) => const AppShell(),
    );

    r.child(
      '/customer',
      child: (context) => const CustomerShell(),
    );
  }
}
