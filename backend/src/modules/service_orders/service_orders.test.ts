import { test, describe } from 'node:test';
import assert from 'node:assert';
import { ServiceOrderStatus } from '@prisma/client';
import { isValidStatusTransition, ALLOWED_TRANSITIONS } from './service_order_state_machine.js';

describe('Service Order State Machine Hardening', () => {
  test('Valid state transitions pass', () => {
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DRAFT, ServiceOrderStatus.DIAGNOSTICO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DIAGNOSTICO, ServiceOrderStatus.AGUARDANDO_APROVACAO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.AGUARDANDO_APROVACAO, ServiceOrderStatus.EM_EXECUCAO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.EM_EXECUCAO, ServiceOrderStatus.PRONTO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.PRONTO, ServiceOrderStatus.ENTREGUE), true);
  });

  test('Cancellation from valid states is allowed', () => {
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DRAFT, ServiceOrderStatus.CANCELADO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DIAGNOSTICO, ServiceOrderStatus.CANCELADO), true);
  });

  test('Invalid backward or skipped transitions are rejected', () => {
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.ENTREGUE, ServiceOrderStatus.DIAGNOSTICO), false);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.CANCELADO, ServiceOrderStatus.EM_EXECUCAO), false);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DRAFT, ServiceOrderStatus.ENTREGUE), false);
  });
});
