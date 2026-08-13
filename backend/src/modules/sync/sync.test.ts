import { test, describe } from 'node:test';
import assert from 'node:assert';
import { computePayloadHash } from '../../core/middleware/idempotency.middleware.js';

describe('Sync Engine & Idempotency Hardening', () => {
  test('computePayloadHash generates deterministic SHA-256 string', () => {
    const payloadA = { name: 'Customer A', email: 'a@example.com' };
    const payloadB = { name: 'Customer A', email: 'a@example.com' };
    const payloadC = { name: 'Customer B', email: 'b@example.com' };

    const hashA = computePayloadHash(payloadA);
    const hashB = computePayloadHash(payloadB);
    const hashC = computePayloadHash(payloadC);

    assert.strictEqual(hashA.length, 64); // SHA-256 hex length
    assert.strictEqual(hashA, hashB);
    assert.notStrictEqual(hashA, hashC);
  });
});
