import { test, describe } from 'node:test';
import assert from 'node:assert';
import { registerSchema } from './auth.schema.js';
import { buildApp } from '../../app.js';

describe('Auth Security & Privilege Escalation Hardening', () => {
  test('Startup fails when JWT_SECRET is missing', () => {
    const oldSecret = process.env.JWT_SECRET;
    delete process.env.JWT_SECRET;

    assert.throws(() => {
      buildApp();
    }, /JWT_SECRET environment variable is missing/);

    process.env.JWT_SECRET = oldSecret || 'test-jwt-secret-key-12345';
  });

  test('Public registration schema rejects role ADMIN', () => {
    const invalidPayload = {
      name: 'Hacker User',
      email: 'hacker@example.com',
      password: 'securepassword123',
      role: 'ADMIN',
    };

    const parseResult = registerSchema.safeParse(invalidPayload);
    assert.strictEqual(parseResult.success, false);
  });

  test('Public registration schema accepts TECHNICIAN or CUSTOMER', () => {
    const validPayload = {
      name: 'Valid Tech',
      email: 'tech@example.com',
      password: 'securepassword123',
      role: 'TECHNICIAN',
    };

    const parseResult = registerSchema.safeParse(validPayload);
    assert.strictEqual(parseResult.success, true);
    if (parseResult.success) {
      assert.strictEqual(parseResult.data.role, 'TECHNICIAN');
    }
  });
});
