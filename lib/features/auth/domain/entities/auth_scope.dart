abstract class AuthScope {
  const AuthScope();

  /// Stable identity used to bind session caches, local databases and offline
  /// authority metadata to the exact authenticated scope.
  String get canonicalKey;
}

class ProfessionalAuthScope extends AuthScope {
  final String userId;
  final String organizationId;

  const ProfessionalAuthScope({
    required this.userId,
    required this.organizationId,
  });

  @override
  String get canonicalKey => 'PROFESSIONAL:$userId:$organizationId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfessionalAuthScope &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          organizationId == other.organizationId;

  @override
  int get hashCode => userId.hashCode ^ organizationId.hashCode;

  @override
  String toString() =>
      'ProfessionalAuthScope(userId: $userId, organizationId: $organizationId)';
}

class CustomerAuthScope extends AuthScope {
  final String userId;
  final String customerId;

  const CustomerAuthScope({
    required this.userId,
    required this.customerId,
  });

  @override
  String get canonicalKey => 'CUSTOMER:$userId:$customerId';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CustomerAuthScope &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          customerId == other.customerId;

  @override
  int get hashCode => userId.hashCode ^ customerId.hashCode;

  @override
  String toString() =>
      'CustomerAuthScope(userId: $userId, customerId: $customerId)';
}

class InvalidAuthScope extends AuthScope {
  final String userId;
  final String role;
  final String reason;

  const InvalidAuthScope({
    required this.userId,
    required this.role,
    required this.reason,
  });

  @override
  String get canonicalKey => throw StateError(
        'InvalidAuthScope has no authoritative canonical key: $reason',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InvalidAuthScope &&
          runtimeType == other.runtimeType &&
          userId == other.userId &&
          role == other.role &&
          reason == other.reason;

  @override
  int get hashCode => userId.hashCode ^ role.hashCode ^ reason.hashCode;

  @override
  String toString() =>
      'InvalidAuthScope(userId: $userId, role: $role, reason: $reason)';
}
