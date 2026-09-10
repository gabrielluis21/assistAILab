import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';
import 'package:assistailab/features/auth/domain/entities/auth_scope.dart';
import 'package:assistailab/features/auth/domain/services/auth_scope_manager.dart';

void main() {
  group('AuthScope & AuthScopeManager Hardening Tests', () {
    test('unauthenticated User == null -> normal unauthenticated state (null)',
        () {
      final scope = AuthScopeManager.scopeFromUser(null);
      expect(scope, isNull);
    });

    test('valid identity: ADMIN -> exact expected ProfessionalAuthScope', () {
      const user = User(
        id: 'u-admin-1',
        name: 'Admin User',
        email: 'admin@org.com',
        role: 'ADMIN',
        status: 'ACTIVE',
        organizationId: 'org-99',
      );

      final scope = AuthScopeManager.scopeFromUser(user);
      expect(
          scope,
          equals(const ProfessionalAuthScope(
              userId: 'u-admin-1', organizationId: 'org-99')));
    });

    test('valid identity: TECHNICIAN -> exact expected ProfessionalAuthScope',
        () {
      const user = User(
        id: 'u-tech-1',
        name: 'Tech User',
        email: 'tech@org.com',
        role: 'TECHNICIAN',
        status: 'ACTIVE',
        organizationId: 'org-99',
      );

      final scope = AuthScopeManager.scopeFromUser(user);
      expect(
          scope,
          equals(const ProfessionalAuthScope(
              userId: 'u-tech-1', organizationId: 'org-99')));
    });

    test('valid identity: CUSTOMER -> exact expected CustomerAuthScope', () {
      const user = User(
        id: 'u-cust-1',
        name: 'Customer User',
        email: 'cust@client.com',
        role: 'CUSTOMER',
        status: 'ACTIVE',
        customerId: 'cust-555',
      );

      final scope = AuthScopeManager.scopeFromUser(user);
      expect(
          scope,
          equals(const CustomerAuthScope(
              userId: 'u-cust-1', customerId: 'cust-555')));
    });

    test(
        'authenticated ADMIN without organizationId -> InvalidAuthScope / fail closed',
        () {
      const user = User(
        id: 'u-admin-bad',
        name: 'Admin Bad',
        email: 'adminbad@org.com',
        role: 'ADMIN',
        status: 'ACTIVE',
        organizationId: null,
      );

      final scope = AuthScopeManager.scopeFromUser(user);
      expect(scope, isA<InvalidAuthScope>());
      expect(
          scope,
          isNot(
              isNull)); // MUST NOT be indistinguishable from unauthenticated null

      final invalidScope = scope as InvalidAuthScope;
      expect(invalidScope.userId, 'u-admin-bad');
      expect(invalidScope.role, 'ADMIN');
    });

    test(
        'authenticated TECHNICIAN without organizationId -> InvalidAuthScope / fail closed',
        () {
      const user = User(
        id: 'u-tech-bad',
        name: 'Tech Bad',
        email: 'techbad@org.com',
        role: 'TECHNICIAN',
        status: 'ACTIVE',
        organizationId: '',
      );

      final scope = AuthScopeManager.scopeFromUser(user);
      expect(scope, isA<InvalidAuthScope>());
      expect(scope, isNot(isNull));

      final invalidScope = scope as InvalidAuthScope;
      expect(invalidScope.userId, 'u-tech-bad');
      expect(invalidScope.role, 'TECHNICIAN');
    });

    test(
        'authenticated CUSTOMER without customerId -> InvalidAuthScope / fail closed',
        () {
      const user = User(
        id: 'u-cust-bad',
        name: 'Customer Bad',
        email: 'custbad@client.com',
        role: 'CUSTOMER',
        status: 'ACTIVE',
        customerId: null,
      );

      final scope = AuthScopeManager.scopeFromUser(user);
      expect(scope, isA<InvalidAuthScope>());
      expect(scope, isNot(isNull));

      final invalidScope = scope as InvalidAuthScope;
      expect(invalidScope.userId, 'u-cust-bad');
      expect(invalidScope.role, 'CUSTOMER');
    });

    test('empty authenticated user id fails closed', () {
      const user = User(
        id: '   ',
        name: 'No Principal',
        email: 'missing@example.com',
        role: 'ADMIN',
        status: 'ACTIVE',
        organizationId: 'org-99',
      );

      expect(AuthScopeManager.scopeFromUser(user), isA<InvalidAuthScope>());
    });

    test('inactive authenticated user fails closed', () {
      const user = User(
        id: 'u-inactive',
        name: 'Inactive',
        email: 'inactive@example.com',
        role: 'TECHNICIAN',
        status: 'DISABLED',
        organizationId: 'org-99',
      );

      expect(AuthScopeManager.scopeFromUser(user), isA<InvalidAuthScope>());
    });

    test('unknown authenticated role fails closed', () {
      const user = User(
        id: 'u-unknown',
        name: 'Unknown',
        email: 'unknown@example.com',
        role: 'SUPERUSER',
        status: 'ACTIVE',
        organizationId: 'org-99',
      );

      expect(AuthScopeManager.scopeFromUser(user), isA<InvalidAuthScope>());
    });

    test('Igualdade e representação de AuthScope', () {
      const scope1 = ProfessionalAuthScope(userId: 'u1', organizationId: 'o1');
      const scope2 = ProfessionalAuthScope(userId: 'u1', organizationId: 'o1');
      const scope3 = ProfessionalAuthScope(userId: 'u1', organizationId: 'o2');

      expect(scope1, equals(scope2));
      expect(scope1, isNot(equals(scope3)));

      const cScope1 = CustomerAuthScope(userId: 'u2', customerId: 'c1');
      const cScope2 = CustomerAuthScope(userId: 'u2', customerId: 'c1');

      expect(cScope1, equals(cScope2));
      expect(scope1, isNot(equals(cScope1)));

      const invScope1 =
          InvalidAuthScope(userId: 'u3', role: 'ADMIN', reason: 'err');
      const invScope2 =
          InvalidAuthScope(userId: 'u3', role: 'ADMIN', reason: 'err');
      expect(invScope1, equals(invScope2));
      expect(invScope1, isNot(equals(scope1)));
    });
  });
}
