import 'package:flutter_test/flutter_test.dart';
import 'package:assistailab/core/database/outbox_dao.dart';

void main() {
  group('OutboxItem Model Tests', () {
    test('Should correctly convert OutboxItem with retry metadata to Map and back', () {
      final item = OutboxItem(
        operationId: '123e4567-e89b-12d3-a456-426614174000',
        deviceId: 'device-01',
        userId: 'user-01',
        entityType: 'CUSTOMER',
        entityId: 'cust-100',
        operationType: 'CREATE',
        payload: {'name': 'João da Silva', 'email': 'joao@example.com'},
        createdAt: '2026-08-11T10:00:00Z',
        attemptCount: 2,
        lastAttemptAt: '2026-08-11T10:05:00Z',
        nextRetryAt: '2026-08-11T10:09:00Z',
        lastError: 'HTTP 500: Server Error',
        status: 'FAILED',
      );

      final map = item.toMap();
      expect(map['operation_id'], equals('123e4567-e89b-12d3-a456-426614174000'));
      expect(map['entity_type'], equals('CUSTOMER'));
      expect(map['attempt_count'], equals(2));
      expect(map['last_error'], equals('HTTP 500: Server Error'));

      final restored = OutboxItem.fromMap(map);
      expect(restored.operationId, equals(item.operationId));
      expect(restored.payload['name'], equals('João da Silva'));
      expect(restored.attemptCount, equals(2));
      expect(restored.lastError, equals('HTTP 500: Server Error'));
      expect(restored.status, equals('FAILED'));
    });
  });
}
