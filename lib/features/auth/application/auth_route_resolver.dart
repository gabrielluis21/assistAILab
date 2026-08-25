import '../domain/entities/user.dart';

abstract final class AuthRouteResolver {
  static const String loginRoute = '/login';
  static const String professionalRoute = '/home';
  static const String customerRoute = '/customer';

  static String routeFor(User? user) {
    if (user == null) {
      return loginRoute;
    }

    switch (user.role.trim().toUpperCase()) {
      case 'CUSTOMER':
        return customerRoute;

      case 'ADMIN':
      case 'TECHNICIAN':
        return professionalRoute;

      default:
        return loginRoute;
    }
  }

  static bool isCustomer(User user) {
    return user.role.trim().toUpperCase() == 'CUSTOMER';
  }

  static bool isProfessional(User user) {
    final role = user.role.trim().toUpperCase();

    return role == 'ADMIN' || role == 'TECHNICIAN';
  }
}