class User {
  final String id;
  final String name;
  final String email;
  final String role;
  final String status;
  final String? customerId;
  final String? organizationId;

  const User({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.status,
    this.customerId,
    this.organizationId,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      email: _requiredString(json, 'email'),
      role: _requiredString(json, 'role'),
      status: _requiredString(json, 'status'),
      customerId: _nullableString(json, 'customerId'),
      organizationId: _nullableString(json, 'organizationId'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'email': email,
      'role': role,
      'status': status,
      'customerId': customerId,
      'organizationId': organizationId,
    };
  }

  static String _requiredString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('User.$key must be a string.');
    }
    return value;
  }

  static String? _nullableString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('User.$key must be a string or null.');
    }
    return value;
  }
}
