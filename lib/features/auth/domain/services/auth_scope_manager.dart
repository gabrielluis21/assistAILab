import '../entities/auth_scope.dart';
import '../entities/user.dart';

class AuthScopeManager {
  /// Resolve autoritativamente o [AuthScope] a partir do [User] fornecido.
  ///
  /// Retorna `null` se o usuário for não autenticado ([User] `null`).
  /// Retorna [CustomerAuthScope] para usuários 'CUSTOMER' com `customerId` válido.
  /// Retorna [ProfessionalAuthScope] para usuários profissionais ('ADMIN', 'TECHNICIAN') com `organizationId` válido.
  /// Retorna [InvalidAuthScope] (fail closed) se o usuário estiver autenticado porém
  /// sem o identificador de autoridade obrigatório.
  static AuthScope? scopeFromUser(User? user) {
    if (user == null) return null;

    final role = user.role.trim().toUpperCase();

    if (user.id.trim().isEmpty) {
      return InvalidAuthScope(
        userId: user.id,
        role: user.role,
        reason: 'Authenticated user is missing authoritative userId',
      );
    }

    if (user.status.trim().toUpperCase() != 'ACTIVE') {
      return InvalidAuthScope(
        userId: user.id,
        role: user.role,
        reason: 'Authenticated user status is not ACTIVE',
      );
    }

    if (role == 'CUSTOMER') {
      final customerId = user.customerId;
      if (customerId == null || customerId.trim().isEmpty) {
        return InvalidAuthScope(
          userId: user.id,
          role: user.role,
          reason: 'CUSTOMER user missing authoritative customerId',
        );
      }
      return CustomerAuthScope(
        userId: user.id,
        customerId: customerId,
      );
    } else if (role == 'ADMIN' || role == 'TECHNICIAN') {
      final organizationId = user.organizationId;
      if (organizationId == null || organizationId.trim().isEmpty) {
        return InvalidAuthScope(
          userId: user.id,
          role: user.role,
          reason:
              'Professional user ($role) missing authoritative organizationId',
        );
      }
      return ProfessionalAuthScope(
        userId: user.id,
        organizationId: organizationId,
      );
    }

    return InvalidAuthScope(
      userId: user.id,
      role: user.role,
      reason: 'Unsupported authenticated role: $role',
    );
  }
}
