import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/features/auth/domain/entities/user.dart';

void main() {
  group('Auth Tests', () {
    test('User serialization', () {
      final user = User(
        id: '1',
        name: 'Test User',
        email: 'test@example.com',
        role: 'TECHNICIAN',
        status: 'ACTIVE',
      );

      final json = user.toJson();
      expect(json['id'], '1');
      expect(json['name'], 'Test User');

      final userFromJson = User.fromJson(json);
      expect(userFromJson.id, '1');
      expect(userFromJson.email, 'test@example.com');
    });
  });
}
