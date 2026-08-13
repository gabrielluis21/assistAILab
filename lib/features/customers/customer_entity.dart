class CustomerEntity {
  final String id;
  final String name;
  final String? document;
  final String? email;
  final String? phone;
  final String? address;
  final String updatedAt;

  CustomerEntity({
    required this.id,
    required this.name,
    this.document,
    this.email,
    this.phone,
    this.address,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'document': document,
      'email': email,
      'phone': phone,
      'address': address,
      'updated_at': updatedAt,
    };
  }

  factory CustomerEntity.fromMap(Map<String, dynamic> map) {
    return CustomerEntity(
      id: map['id'],
      name: map['name'],
      document: map['document'],
      email: map['email'],
      phone: map['phone'],
      address: map['address'],
      updatedAt: map['updated_at'],
    );
  }
}
