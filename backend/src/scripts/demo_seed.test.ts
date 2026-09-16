import test from 'node:test';
import assert from 'node:assert/strict';
import { z } from 'zod';
import { normalizeSyncEntry, pushSyncSchema } from '../modules/sync/sync.schema.js';
import { assertDemoDatabase, demoId, demoScenarios, seedDemoScenario, type DemoTransport } from './demo_seed.plan.js';
import { demoCustomerOrderSchema } from './demo_seed.js';

function recorder() {
  const calls: unknown[] = [];
  const transport: DemoTransport = {
    push: async entry => {
      pushSyncSchema.parse({ contractVersion: 2, entries: [entry] });
      normalizeSyncEntry(entry, 2);
      assert.ok(['SERVICE_ORDER', 'SERVICE_ORDER_ITEM'].includes(entry.entityType));
      assert.ok(!Object.hasOwn(entry.payload, 'partId'));
      calls.push({ entry });
    },
    post: async (path, payload, operationId, customer) => {
      z.string().uuid().parse(operationId);
      calls.push({ path, payload, operationId, customer });
      return { quoteRevision: { id: demoId(`server-result:${operationId}`) } };
    },
  };
  return { transport, calls };
}

test('all demo scenarios use strict v2 money inputs without generic PART or Payment authority', async () => {
  const run = recorder();
  for (const scenario of demoScenarios) await seedDemoScenario(scenario, run.transport);
  const entries = run.calls.filter((c: any) => c.entry) as any[];
  assert.equal(entries.filter(c => c.entry.entityType === 'SERVICE_ORDER_ITEM').length, demoScenarios.length * 2);
  assert.equal(new Set(entries.map(c => c.entry.operationId)).size, entries.length);
});

test('rerunning demo scenarios preserves operation identities and payloads for safe replay', async () => {
  const first = recorder(), second = recorder();
  for (const scenario of demoScenarios) {
    await seedDemoScenario(scenario, first.transport);
    await seedDemoScenario(scenario, second.transport);
  }
  assert.deepEqual(first.calls, second.calls);
});

test('customer decisions bind the returned revision; resume uses its dedicated command', async () => {
  const run = recorder();
  await seedDemoScenario(demoScenarios.find(s => s.stage === 'resumed')!, run.transport);
  const calls = run.calls.filter((c: any) => c.path) as any[];
  const publish = calls.find(c => c.path.endsWith('/quotes/publish'));
  const revise = calls.find(c => c.path.endsWith('/quotes/revise'));
  const decisions = calls.filter(c => c.path.endsWith('/quote-decision'));
  assert.deepEqual(decisions.map(c => [c.customer, c.payload.decision, c.payload.quoteRevisionId]), [
    [true, 'APPROVE', demoId(`server-result:${publish.operationId}`)],
    [true, 'REJECT', demoId(`server-result:${revise.operationId}`)],
  ]);
  assert.ok(calls.at(-1).path.endsWith('/quotes/resume-approved-scope'));
});

test('demo stops after a rejected application command instead of fabricating later state', async () => {
  const run = recorder();
  let commands = 0;
  run.transport.post = async () => { commands++; throw new Error('command rejected'); };
  await assert.rejects(seedDemoScenario(demoScenarios.find(s => s.stage === 'ready')!, run.transport), /command rejected/);
  assert.equal(commands, 1);
});

test('demo CUSTOMER verification rejects internal root fields and item references', () => {
  const data = { contractVersion: 2, projectionRevision: '42', id: demoId('order'), friendlyId: 1,
    equipmentId: demoId('equipment'), status: 'DIAGNOSTICO', problemDescription: 'Problem', solution: null,
    diagnosis: 'Diagnosis', createdAt: '2026-09-16T00:00:00Z', updatedAt: '2026-09-16T00:00:00Z', totalAmountMinor: 2468,
    items: [{ description: 'Labor', quantity: 2, unitPriceMinor: 1234, totalPriceMinor: 2468 }] };
  assert.doesNotThrow(() => demoCustomerOrderSchema.parse(data));
  for (const key of ['organizationId', 'customerId', 'technicianId', 'financeCoreVersion', 'currentQuoteRevisionId',
    'lastApprovedQuoteRevisionId', 'materializedQuoteRevisionId', 'commercialScopeSource', 'quoteHash', 'quoteSnapshot', 'financialAuditEvents']) {
    assert.throws(() => demoCustomerOrderSchema.parse({ ...data, [key]: 'private' }));
  }
  for (const key of ['id', 'serviceOrderId', 'partId', 'createdAt']) {
    assert.throws(() => demoCustomerOrderSchema.parse({ ...data, items: [{ ...data.items[0], [key]: 'private' }] }));
  }
});
test('demo seed only targets its separate demonstration database', () => {
  const env = { NODE_ENV: 'development', DATABASE_URL: 'mysql://localhost/assistailab_fe02b_demo', JWT_SECRET: 'demo-test-only' };
  assert.doesNotThrow(() => assertDemoDatabase(env));
  for (const NODE_ENV of ['production', 'test']) assert.throws(() => assertDemoDatabase({ ...env, NODE_ENV }));
  for (const database of ['assistailab', 'assistailab_fe02b_test', 'other_database']) assert.throws(() => assertDemoDatabase({ ...env, DATABASE_URL: `mysql://localhost/${database}` }));
  assert.throws(() => assertDemoDatabase({ ...env, JWT_SECRET: undefined }));
});
