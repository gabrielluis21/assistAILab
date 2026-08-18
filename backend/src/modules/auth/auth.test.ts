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

    if (oldSecret) {
      process.env.JWT_SECRET = oldSecret;
    } else {
      process.env.JWT_SECRET = 'test-jwt-secret-key-12345';
    }
  });

  test('Public registration rejects role injection', () => {
    const invalidPayload = {
      name: 'Hacker User',
      email: 'hacker@example.com',
      password: 'securepassword123',
      organizationId: '550e8400-e29b-41d4-a716-446655440000',
      role: 'ADMIN',
    };

    const parseResult = registerSchema.safeParse(invalidPayload);

    assert.strictEqual(parseResult.success, true);

    if (parseResult.success) {
      assert.strictEqual(
        'role' in parseResult.data,
        false,
      );
    }
  });

  test('Public registration requires a password', () => {
    const invalidPayload = {
      name: 'Test User',
      email: 'test@example.com',
      organizationId: '550e8400-e29b-41d4-a716-446655440000',
    };

    const parseResult = registerSchema.safeParse(invalidPayload);

    assert.strictEqual(parseResult.success, false);
  });

  test('Public registration accepts valid customer data', () => {
    const validPayload = {
      name: 'Valid Customer',
      email: 'customer@example.com',
      password: 'securepassword123',
      phone: '16999999999',
      organizationId: '550e8400-e29b-41d4-a716-446655440000',
    };

    const parseResult = registerSchema.safeParse(validPayload);

    assert.strictEqual(parseResult.success, true);
  });
});