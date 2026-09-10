class User {
  final String id;
  final String name;
  final String email;
  final String role;
  final String status;
  final String? customerId;
  final String? organizationId;

  User({
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
      id: json['id'],
      name: json['name'],
      email: json['email'],
      role: json['role'],
      status: json['status'],
      customerId: json['customerId'],
      organizationId: json['organizationId'],
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
}
