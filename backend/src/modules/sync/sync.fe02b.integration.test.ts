import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { prisma } from '../../core/database/prisma.js';
import { syncTransaction, syncRead } from '../../core/database/sync_transaction.js';
import { buildApp } from '../../app.js';
import { captureBootstrap, issueBootstrapProof } from './sync.bootstrap.js';
import { readProjection } from './sync.projection.js';
import { IdempotencyService, IdempotencyStateConflictError } from '../../core/idempotency/idempotency.service.js';
import { ServiceOrderFinanceService } from '../service_order_finance/service_order_finance.service.js';
import { CustomerQuoteDecisionFinanceService } from '../service_order_finance/customer_quote_decision.service.js';
import { CommercialQuoteRevisionService } from '../service_order_finance/commercial_quote_revision.service.js';
import { ResumeApprovedScopeService } from '../service_order_finance/resume_approved_scope.service.js';
import { assertCustomerOrderPrivacy } from './sync.customer-projection.test-helpers.js';

// Run only against a disposable database populated with EXISTING migrations.
// These tests intentionally retain immutable financial history until DB disposal.
test('FE-02B MySQL authority, bootstrap and concurrency gate', { timeout: 120000 }, async t => {
  assert.ok(process.env.DATABASE_URL, 'DATABASE_URL must point to an isolated MySQL test database');
  process.env.JWT_SECRET = 'fe02b-integration-test-only';
  const org = await prisma.organization.create({ data: { name: `FE02B ${randomUUID()}` } });
  const otherOrg = await prisma.organization.create({ data: { name: `Other ${randomUUID()}` } });
  const customer = await prisma.customer.create({ data: { name: 'Customer' } });
  const actor = await prisma.user.create({ data: { name: 'Staff', email: `${randomUUID()}@test.invalid`, passwordHash: 'unused', role: 'ADMIN', status: 'ACTIVE' } });
  const customerUser = await prisma.user.create({ data: { name: 'Customer', email: `${randomUUID()}@test.invalid`, passwordHash: 'unused', role: 'CUSTOMER', status: 'ACTIVE', customerId: customer.id } });
  await prisma.membership.create({ data: { userId: actor.id, organizationId: org.id, role: 'ADMIN' } });
  await prisma.customerOrganization.create({ data: { customerId: customer.id, organizationId: org.id } });
  const equipment = await prisma.equipment.create({ data: { customerId: customer.id, type: 'Computer', brand: 'Test', model: 'Fixture' } });
  const order = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
    financeCoreVersion: 2, status: 'DIAGNOSTICO', problemDescription: 'Test', totalAmount: '0.00' } });
  const principal = { sub: actor.id, name: actor.name, role: 'ADMIN' as const, organizationId: org.id, customerId: null };
  const app = buildApp();
  await app.ready();
  const headers = { authorization: `Bearer ${app.jwt.sign(principal)}` };
  const outbox = (payload: any, type = 'SERVICE_ORDER_ITEM', operationType = 'CREATE', entityId: string = randomUUID(), operationId: string = randomUUID()) => ({
    operationId, entityId, entityType: type, operationType, payload, createdAt: new Date().toISOString(),
  });
  const send = (entry: any, contractVersion = 1, proof?: string) => app.inject({ method: 'POST', url: '/api/v1/sync/push',
    headers: { ...headers, ...(proof ? { 'x-sync-bootstrap-proof': proof } : {}) }, payload: { contractVersion, entries: [entry] } });
  try {
    await t.test('v2 Push and Pull require activation and proof never substitutes for JWT', async () => {
      const body = outbox({ serviceOrderId: order.id, description: 'Labor', quantity: 1, unitPriceMinor: 100 });
      assert.equal((await send(body, 2)).statusCode, 409);
      assert.equal((await app.inject({ method: 'GET', url: '/api/v1/sync/changes?contractVersion=2&cursor=0', headers })).statusCode, 409);
      assert.equal((await app.inject({ method: 'POST', url: '/api/v1/sync/bootstrap', payload: { contractVersion: 2 },
        headers: { 'x-sync-bootstrap-proof': issueBootstrapProof(principal, '0') } })).statusCode, 401);
    });
    await t.test('v1 cannot recover missing money, create by UPDATE, derived authority or PART', async () => {
      for (const payload of [{}, { unitPrice: -1 }, { unitPrice: 0.1 + 0.2 }, { unitPrice: '1.001' }]) {
        const response = await send(outbox({ serviceOrderId: order.id, description: 'Labor', quantity: 1, ...payload }));
        assert.equal(response.json().results[0].status, 'FAILED');
      }
      const missing = await send(outbox({ unitPrice: '1.00' }, 'SERVICE_ORDER_ITEM', 'UPDATE'));
      assert.equal(missing.json().results[0].status, 'FAILED');
      assert.equal((await send(outbox({ totalAmount: '99.00' }, 'SERVICE_ORDER', 'UPDATE', order.id))).json().results[0].status, 'FAILED');
      assert.equal((await send(outbox({}, 'PART'))).json().results[0].error, 'PART_TENANCY_REQUIRED');
    });
    const itemEntry = outbox({ serviceOrderId: order.id, description: 'Labor', quantity: 2, unitPrice: '12.34', totalPrice: '24.68' });
    await t.test('v1 exact adapter, server aggregation and idempotent replay commit once', async () => {
      const first = await send(itemEntry);
      assert.equal(first.json().results[0].status, 'SYNCED', first.body);
      assert.deepEqual((await send(itemEntry)).json(), first.json());
      const saved = await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id } });
      assert.equal(saved.totalAmount.toString(), '24.68');
      assert.equal(await prisma.serviceOrderItem.count({ where: { id: itemEntry.entityId } }), 1);
      const idem = await prisma.operationIdempotency.findUniqueOrThrow({ where: { operationId: itemEntry.operationId } });
      assert.equal(idem.command, 'SYNC_V1_SERVICE_ORDER_ITEM_CREATE');
      assert.equal(idem.status, 'COMPLETED');
      const changed = await send({ ...itemEntry, entityId: randomUUID() });
      assert.equal(changed.json().results[0].error, 'IDEMPOTENCY_KEY_REUSE');
    });
    await t.test('v1 generic order mutation repairs legacy derived money, including empty orders', async () => {
      const empty = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
        financeCoreVersion: null, status: 'DIAGNOSTICO', problemDescription: 'Legacy empty', totalAmount: '9.99' } });
      const emptyResponse = await send(outbox({ solution: 'Repair empty aggregate' }, 'SERVICE_ORDER', 'UPDATE', empty.id));
      assert.equal(emptyResponse.json().results[0].status, 'SYNCED', emptyResponse.body);
      assert.equal((await prisma.serviceOrder.findUniqueOrThrow({ where: { id: empty.id } })).totalAmount.toString(), '0');

      const populated = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
        financeCoreVersion: null, status: 'DIAGNOSTICO', problemDescription: 'Legacy populated', totalAmount: '99.99' } });
      const legacyItem = await prisma.serviceOrderItem.create({ data: { serviceOrderId: populated.id, description: 'Legacy line',
        quantity: 3, unitPrice: '1.25', totalPrice: '0.01' } });
      const populatedResponse = await send(outbox({ solution: 'Repair populated aggregate' }, 'SERVICE_ORDER', 'UPDATE', populated.id));
      assert.equal(populatedResponse.json().results[0].status, 'SYNCED', populatedResponse.body);
      assert.equal((await prisma.serviceOrder.findUniqueOrThrow({ where: { id: populated.id } })).totalAmount.toString(), '3.75');
      assert.equal((await prisma.serviceOrderItem.findUniqueOrThrow({ where: { id: legacyItem.id } })).totalPrice.toString(), '3.75');
    });
    let snapshot = await captureBootstrap(principal);
    let proof = issueBootstrapProof(principal, snapshot.revision);
    await t.test('bootstrap pages form one snapshot and activate only after the final page', async () => {
      const first = await app.inject({ method: 'POST', url: '/api/v1/sync/bootstrap', headers, payload: { contractVersion: 2, limit: 1 } });
      assert.equal(first.statusCode, 200, first.body);
      let page = first.json();
      assert.equal(page.bootstrapProof, null);
      const records = [...page.records];
      while (!page.complete) {
        const response = await app.inject({ method: 'POST', url: '/api/v1/sync/bootstrap', headers, payload: { contractVersion: 2, limit: 1, continuationToken: page.continuationToken } });
        assert.equal(response.statusCode, 200, response.body);
        page = response.json(); records.push(...page.records);
      }
      proof = page.bootstrapProof;
      const canonical = records.find((r: any) => r.entityType === 'SERVICE_ORDER' && r.entityId === order.id).data;
      assert.equal(canonical.totalAmountMinor, 2468);
      assert.equal(canonical.items.length, 1);
      assert.equal(canonical.projectionRevision, page.bootstrapCursor);
      assert.equal('financeCoreVersion' in canonical, false);
      const wrongVersion = { ...itemEntry, payload: { serviceOrderId: order.id, description: 'Labor', quantity: 2, unitPriceMinor: 1234 } };
      assert.equal((await send(wrongVersion, 2, proof)).json().results[0].error, 'IDEMPOTENCY_KEY_REUSE');
    });
    await t.test('v2 deletion converges via full aggregate, even when page limit splits item and OS events', async () => {
      const before = await captureBootstrap(principal);
      const activeProof = issueBootstrapProof(principal, before.revision);
      const response = await send(outbox({}, 'SERVICE_ORDER_ITEM', 'DELETE', itemEntry.entityId), 2, activeProof);
      assert.equal(response.json().results[0].status, 'SYNCED', response.body);
      const pull = await app.inject({ method: 'GET', url: `/api/v1/sync/changes?contractVersion=2&cursor=${before.revision}&limit=1`, headers: { ...headers, 'x-sync-bootstrap-proof': activeProof } });
      assert.equal(pull.statusCode, 200, pull.body);
      const aggregate = pull.json().changes[0];
      assert.equal(aggregate.entityType, 'SERVICE_ORDER');
      assert.equal(aggregate.data.items.length, 0);
      assert.equal(aggregate.data.totalAmountMinor, 0);
    });
    await t.test('historical idempotency cannot replay sensitive payload or reset PROCESSING', async () => {
      const op = randomUUID();
      await prisma.operationIdempotency.create({ data: { operationId: op, userId: actor.id, endpoint: '/api/v1/sync/push', requestHash: 'legacy',
        status: 'PROCESSING', responseBody: { secret: 'must not leak' }, responseStatus: 102 } });
      const response = await send(outbox({}, 'SERVICE_ORDER_ITEM', 'UPDATE', randomUUID(), op));
      assert.equal(response.json().results[0].error, 'LEGACY_OPERATION_RECONCILIATION_REQUIRED');
      assert.equal(response.body.includes('must not leak'), false);
      assert.equal((await prisma.operationIdempotency.findUniqueOrThrow({ where: { operationId: op } })).status, 'PROCESSING');
    });
    await t.test('high-water cut waits for pending writer; later commits cannot get lost below H', async () => {
      let announce!: () => void; let release!: () => void;
      const entered = new Promise<void>(resolve => { announce = resolve; });
      const gate = new Promise<void>(resolve => { release = resolve; });
      const writing = syncTransaction(async tx => {
        await tx.serviceOrder.update({ where: { id: order.id }, data: { solution: 'Committed before H' } });
        announce(); await gate;
      });
      await entered;
      let captured = false;
      const capturing = captureBootstrap(principal).then(result => { captured = true; return result; });
      await new Promise(resolve => setTimeout(resolve, 50));
      assert.equal(captured, false, 'bootstrap must wait for the pending projected commit');
      release();
      await writing;
      const cut = await capturing;
      const state = cut.records.find(r => r.entityId === order.id)!.data as any;
      assert.equal(state.solution, 'Committed before H');
      await syncTransaction(tx => tx.serviceOrder.update({ where: { id: order.id }, data: { solution: 'After H' } }));
      const next = await syncRead(async (tx, revision) => ({ revision, record: await readProjection(tx, principal, 'SERVICE_ORDER', order.id, revision, 2),
        events: await tx.syncChangeLog.findMany({ where: { id: { gt: BigInt(cut.revision) }, entityId: order.id } }) }));
      assert.ok(BigInt(next.revision) > BigInt(cut.revision));
      assert.ok(next.events.length > 0);
      assert.equal((next.record!.data as any).solution, 'After H');
      assert.equal((next.record!.data as any).projectionRevision, next.revision);
    });
    await t.test('ServiceOrder observer covers every mutation method and coalesces the final canonical row', async () => {
      const created = await syncTransaction(tx => tx.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id,
        equipmentId: equipment.id, status: 'DIAGNOSTICO', problemDescription: 'Observed create' } }));
      let events = await prisma.syncChangeLog.findMany({ where: { entityId: created.id }, orderBy: { id: 'asc' } });
      assert.equal(events.length, 1);
      assert.equal(events[0].operationType, 'CREATE');

      await syncTransaction(async tx => {
        await tx.serviceOrder.update({ where: { id: created.id }, data: { diagnosis: 'First intermediate value' } });
        await tx.serviceOrder.update({ where: { id: created.id }, data: { diagnosis: 'Canonical diagnosis', solution: 'Canonical solution' } });
      });
      events = await prisma.syncChangeLog.findMany({ where: { entityId: created.id }, orderBy: { id: 'asc' } });
      assert.equal(events.length, 2);
      assert.equal(events[1].operationType, 'UPDATE');
      assert.equal((events[1].data as any).diagnosis, 'Canonical diagnosis');
      assert.equal((events[1].data as any).solution, 'Canonical solution');

      await syncTransaction(tx => tx.serviceOrder.updateMany({ where: { id: created.id }, data: { solution: 'Observed updateMany' } }));
      await syncTransaction(tx => tx.serviceOrder.upsert({ where: { id: created.id }, update: { solution: 'Observed upsert update' },
        create: { id: created.id, organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
          status: 'DIAGNOSTICO', problemDescription: 'Unreachable create' } }));
      events = await prisma.syncChangeLog.findMany({ where: { entityId: created.id }, orderBy: { id: 'asc' } });
      assert.equal(events.length, 4);
      assert.deepEqual(events.slice(2).map(event => event.operationType), ['UPDATE', 'UPDATE']);

      const upsertedId = randomUUID();
      await syncTransaction(tx => tx.serviceOrder.upsert({ where: { id: upsertedId }, update: { solution: 'Unreachable update' },
        create: { id: upsertedId, organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
          status: 'DIAGNOSTICO', problemDescription: 'Observed upsert create' } }));
      assert.equal((await prisma.syncChangeLog.findFirstOrThrow({ where: { entityId: upsertedId } })).operationType, 'CREATE');

      await syncTransaction(tx => tx.serviceOrder.delete({ where: { id: upsertedId } }));
      events = await prisma.syncChangeLog.findMany({ where: { entityId: upsertedId }, orderBy: { id: 'asc' } });
      assert.deepEqual(events.map(event => event.operationType), ['CREATE', 'DELETE']);

      const deletedMany = await Promise.all([1, 2].map(index => prisma.serviceOrder.create({ data: { organizationId: org.id,
        customerId: customer.id, equipmentId: equipment.id, status: 'DIAGNOSTICO', problemDescription: `Observed deleteMany ${index}` } })));
      await syncTransaction(tx => tx.serviceOrder.deleteMany({ where: { id: { in: deletedMany.map(value => value.id) } } }));
      for (const deleted of deletedMany) {
        const change = await prisma.syncChangeLog.findFirstOrThrow({ where: { entityId: deleted.id } });
        assert.equal(change.operationType, 'DELETE');
      }
    });
    await t.test('legacy not-approved updateMany path publishes exactly one canonical event', async () => {
      const legacy = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
        financeCoreVersion: null, status: 'AGUARDANDO_APROVACAO', problemDescription: 'Legacy cancellation' } });
      const before = await prisma.syncChangeLog.count({ where: { entityId: legacy.id } });
      const response = await app.inject({ method: 'POST', url: `/api/v1/service-orders/${legacy.id}/not-approved`, headers,
        payload: { reason: 'Customer declined legacy quote' } });
      assert.equal(response.statusCode, 200, response.body);
      assert.equal((await prisma.serviceOrder.findUniqueOrThrow({ where: { id: legacy.id } })).status, 'CANCELADO');
      const events = await prisma.syncChangeLog.findMany({ where: { entityId: legacy.id }, orderBy: { id: 'asc' } });
      assert.equal(events.length, before + 1);
      assert.equal(events.at(-1)!.operationType, 'UPDATE');
      assert.equal((events.at(-1)!.data as any).status, 'CANCELADO');
    });
    await t.test('stale lease completion rolls back the mutation and every ChangeLog event', async () => {
      const identity = { operationId: randomUUID(), actorUserId: actor.id, organizationId: org.id, command: 'SYNC_V2_SERVICE_ORDER_UPDATE', endpoint: '/api/v1/sync/push', requestHash: 'lease-race' };
      const reservation = await new IdempotencyService(prisma).reserveOrReplay(identity);
      assert.equal(reservation.kind, 'ACQUIRED');
      const before = await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id } });
      const count = await prisma.syncChangeLog.count({ where: { entityId: order.id } });
      await assert.rejects(syncTransaction(async tx => {
        await tx.serviceOrder.update({ where: { id: order.id }, data: { solution: 'must rollback' } });
        await IdempotencyService.completeWithinTransaction(tx, { ...identity, leaseToken: 'stale-worker', responseStatus: 200, responseBody: { status: 'SYNCED' } });
      }), IdempotencyStateConflictError);
      assert.equal((await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id } })).solution, before.solution);
      assert.equal(await prisma.syncChangeLog.count({ where: { entityId: order.id } }), count);
    });
    await t.test('item mutation and quote publication share one authority lock', async () => {
      const racing = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id, equipmentId: equipment.id,
        status: 'DIAGNOSTICO', financeCoreVersion: 2, problemDescription: 'Concurrent publication', totalAmount: '1.00' } });
      await prisma.serviceOrderItem.create({ data: { serviceOrderId: racing.id, description: 'Base labor', quantity: 1, unitPrice: '1.00', totalPrice: '1.00' } });
      const [adding, publishing] = await Promise.all([
        send(outbox({ serviceOrderId: racing.id, description: 'Additional labor', quantity: 1, unitPrice: '1.00' })),
        new ServiceOrderFinanceService().publishInitialQuote(org.id, actor.id, randomUUID(), racing.id, {}),
      ]);
      assert.equal(publishing.statusCode, 201, JSON.stringify(publishing.body));
      const applied = adding.json().results[0].status === 'SYNCED';
      const result = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${racing.id}/projection`, headers });
      assert.equal(result.statusCode, 200, result.body);
      assert.equal(result.json().totalAmountMinor, applied ? 200 : 100);
      assert.equal(result.json().items.length, applied ? 2 : 1);
      assert.equal(result.json().materializedQuoteRevisionId, result.json().currentQuoteRevisionId);
    });
    await t.test('initial quote repairs stale derived totals; v2 snapshots survive approve, revise, reject and resume', async () => {
      const historicalPart = await prisma.part.create({ data: { name: 'Secret global name', sku: randomUUID(), price: '999.99', costPrice: '1.00' } });
      const line = await prisma.serviceOrderItem.create({ data: { serviceOrderId: order.id, description: 'Labor', quantity: 2, unitPrice: '10.00', totalPrice: '0.00', partId: historicalPart.id } });
      const published = await new ServiceOrderFinanceService().publishInitialQuote(org.id, actor.id, randomUUID(), order.id, {});
      assert.equal(published.statusCode, 201, JSON.stringify(published.body));
      let current = await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id }, include: { currentQuoteRevision: true } });
      assert.equal(current.totalAmount.toString(), '20');
      const initial = current.currentQuoteRevision!;
      assert.equal((initial.quoteSnapshot as any).snapshotVersion, 2);
      assert.deepEqual(initial.partsSnapshot, []);
      assert.equal(JSON.stringify(initial.quoteSnapshot).includes('Secret global name'), false);
      const decision = new CustomerQuoteDecisionFinanceService();
      assert.equal((await decision.decideExactQuoteRevision(customer.id, customerUser.id, randomUUID(), order.id, { quoteRevisionId: initial.id, decision: 'APPROVE' })).statusCode, 200);
      const revise = new CommercialQuoteRevisionService();
      const revisionInput = { diagnosis: 'Updated diagnosis', changeReason: 'Customer scope change', items: [{ id: line.id, description: 'Revised labor', quantity: 2, unitPriceMinor: 1200 }] };
      const changed = await revise.publishCommercialRevision(org.id, actor.id, randomUUID(), order.id, revisionInput);
      assert.equal(changed.statusCode, 201, JSON.stringify(changed.body));
      current = await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id }, include: { currentQuoteRevision: true } });
      assert.equal((current.currentQuoteRevision!.quoteSnapshot as any).serviceItems[0].partId, historicalPart.id);
      assert.equal((await decision.decideExactQuoteRevision(customer.id, customerUser.id, randomUUID(), order.id, { quoteRevisionId: current.currentQuoteRevisionId!, decision: 'REJECT', reason: 'Declined' })).statusCode, 200);
      const rejectedProjection = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers });
      assert.equal(rejectedProjection.json().materializedQuoteRevisionId, current.currentQuoteRevisionId);
      const resumed = await new ResumeApprovedScopeService().resumePriorApprovedScope(org.id, actor.id, randomUUID(), order.id, { reason: 'Resume approved scope' });
      assert.equal(resumed.statusCode, 200, JSON.stringify(resumed.body));
      const restored = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers });
      assert.equal(restored.json().materializedQuoteRevisionId, initial.id);
      assert.equal(restored.json().currentQuoteRevisionId, current.currentQuoteRevisionId);
      assert.equal(restored.json().commercialScopeSource, 'LAST_APPROVED_QUOTE');
      assert.equal(restored.json().totalAmountMinor, 2000);
      const forbidden = await revise.publishCommercialRevision(org.id, actor.id, randomUUID(), order.id, { ...revisionInput, items: [{ ...revisionInput.items[0], partId: randomUUID() }] });
      assert.equal((forbidden.body as any).error, 'PART_TENANCY_REQUIRED');
    });
    await t.test('CUSTOMER privacy across projection, bootstrap and incremental rehydration', async t => {
      const customerHeaders = { authorization: `Bearer ${app.jwt.sign({ sub: customerUser.id, name: customerUser.name,
        role: 'CUSTOMER', organizationId: null, customerId: customer.id })}` };
      const stranger = await prisma.customer.create({ data: { name: 'Other customer' } });
      const strangerUser = await prisma.user.create({ data: { name: 'Other customer', email: `${randomUUID()}@test.invalid`,
        passwordHash: 'unused', role: 'CUSTOMER', status: 'ACTIVE', customerId: stranger.id } });
      const strangerHeaders = { authorization: `Bearer ${app.jwt.sign({ sub: strangerUser.id, name: strangerUser.name,
        role: 'CUSTOMER', organizationId: null, customerId: stranger.id })}` };
      const otherStaff = await prisma.user.create({ data: { name: 'Other staff', email: `${randomUUID()}@test.invalid`, passwordHash: 'unused', role: 'ADMIN', status: 'ACTIVE' } });
      await prisma.membership.create({ data: { userId: otherStaff.id, organizationId: otherOrg.id, role: 'ADMIN' } });
      const otherHeaders = { authorization: `Bearer ${app.jwt.sign({ sub: otherStaff.id, name: otherStaff.name, role: 'ADMIN', organizationId: otherOrg.id, customerId: null })}` };
      const strangerEquipment = await prisma.equipment.create({ data: { customerId: stranger.id, type: 'Computer', brand: 'Other', model: 'Other' } });
      const foreignOrder = await syncTransaction(tx => tx.serviceOrder.create({ data: { organizationId: otherOrg.id, customerId: stranger.id,
        equipmentId: strangerEquipment.id, status: 'DIAGNOSTICO', problemDescription: 'PRIVATE_OTHER_CUSTOMER', totalAmount: '0.00' } }));
      const checkValues = (data: any) => {
        assertCustomerOrderPrivacy(data);
        assert.equal(data.id, order.id);
        assert.equal(data.totalAmountMinor, 2000);
        assert.deepEqual(data.items.map((item: any) => [item.description, item.quantity, item.unitPriceMinor, item.totalPriceMinor]), [['Labor', 2, 1000, 2000]]);
      };
      let customerProof: string;
      let customerCursor: string;
      await t.test('projection endpoint hides internals and keeps ownership/staff boundaries', async () => {
        const response = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers: customerHeaders });
        assert.equal(response.statusCode, 200, response.body);
        checkValues(response.json());
        for (const deniedHeaders of [strangerHeaders, otherHeaders]) {
          assert.equal((await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers: deniedHeaders })).statusCode, 404);
        }
        assert.equal((await app.inject({ method: 'GET', url: `/api/v1/service-orders/${foreignOrder.id}/projection`, headers: customerHeaders })).statusCode, 404);
        const staff = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers });
        assert.equal(staff.statusCode, 200, staff.body);
        assert.equal(staff.json().organizationId, org.id);
        assert.ok(staff.json().items[0].partId);
        assert.ok(staff.json().currentQuoteRevisionId);
        assert.ok(staff.json().materializedQuoteRevisionId);
      });
      await t.test('paginated bootstrap emits only sanitized owned OS aggregates', async () => {
        let continuationToken: string | undefined;
        const records: any[] = [];
        do {
          const response = await app.inject({ method: 'POST', url: '/api/v1/sync/bootstrap', headers: customerHeaders,
            payload: { contractVersion: 2, limit: 1, ...(continuationToken ? { continuationToken } : {}) } });
          assert.equal(response.statusCode, 200, response.body);
          const page = response.json(); records.push(...page.records);
          if (page.complete) { customerProof = page.bootstrapProof; customerCursor = page.bootstrapCursor; break; }
          assert.ok(page.continuationToken); continuationToken = page.continuationToken;
        } while (true);
        const orders = records.filter(r => r.entityType === 'SERVICE_ORDER');
        for (const record of orders) assertCustomerOrderPrivacy(record.data);
        checkValues(orders.find(r => r.entityId === order.id).data);
        assert.equal(orders.some(r => r.entityId === foreignOrder.id), false);
      });
      await t.test('incremental pull rehydrates sanitized current state and skips another customer', async () => {
        await syncTransaction(async tx => {
          await tx.serviceOrder.update({ where: { id: foreignOrder.id }, data: { solution: 'PRIVATE_OTHER_CUSTOMER_UPDATE' } });
          await tx.serviceOrder.update({ where: { id: order.id }, data: { solution: 'Customer-visible progress' } });
        });
        let cursor = customerCursor!;
        const changes: any[] = [];
        for (let pageIndex = 0; pageIndex < 20; pageIndex++) {
          const response = await app.inject({ method: 'GET', url: `/api/v1/sync/changes?contractVersion=2&cursor=${cursor}&limit=1`,
            headers: { ...customerHeaders, 'x-sync-bootstrap-proof': customerProof! } });
          assert.equal(response.statusCode, 200, response.body);
          const body = response.json(); changes.push(...body.changes);
          if (body.nextCursor === cursor) break;
          cursor = body.nextCursor;
        }
        assert.ok(BigInt(cursor) > BigInt(customerCursor!));
        assert.equal(changes.some(c => c.entityId === foreignOrder.id), false);
        assert.equal(JSON.stringify(changes).includes('PRIVATE_OTHER_CUSTOMER'), false);
        const changed = changes.find(c => c.entityType === 'SERVICE_ORDER' && c.entityId === order.id);
        assert.ok(changed, 'The authorized update must be delivered');
        checkValues(changed.data);
        assert.equal(changed.data.solution, 'Customer-visible progress');
        assert.ok(BigInt(changed.data.projectionRevision) > BigInt(customerCursor!));
      });
    });
    await t.test('type/tenant collisions cannot leak; authorized corrupt history blocks cursor', async () => {
      snapshot = await captureBootstrap(principal);
      proof = issueBootstrapProof(principal, snapshot.revision);
      const other = await syncTransaction(tx => tx.serviceOrder.create({ data: { organizationId: otherOrg.id, customerId: customer.id, equipmentId: equipment.id, status: 'DIAGNOSTICO', problemDescription: 'Other tenant secret' } }));
      await prisma.syncChangeLog.create({ data: { cursor: randomUUID(), entityType: 'PART', entityId: order.id, operationType: 'UPDATE', data: { name: 'Secret Part' } } });
      const read = await app.inject({ method: 'GET', url: `/api/v1/sync/changes?contractVersion=2&cursor=${snapshot.revision}`, headers: { ...headers, 'x-sync-bootstrap-proof': proof } });
      assert.equal(read.statusCode, 200, read.body);
      assert.equal(read.body.includes(other.id), false);
      assert.equal(read.body.includes('Secret'), false);
      assert.ok(BigInt(read.json().nextCursor) > BigInt(snapshot.revision));
      await prisma.serviceOrder.update({ where: { id: order.id }, data: { totalAmount: '0.01' } });
      await prisma.syncChangeLog.create({ data: { cursor: randomUUID(), entityType: 'SERVICE_ORDER', entityId: order.id, operationType: 'UPDATE', data: { totalAmount: 0.01 } } });
      const blocked = await app.inject({ method: 'GET', url: `/api/v1/sync/changes?contractVersion=2&cursor=${read.json().nextCursor}`, headers: { ...headers, 'x-sync-bootstrap-proof': proof } });
      assert.equal(blocked.statusCode, 409, blocked.body);
      assert.equal(blocked.json().error, 'SYNC_V2_REFRESH_REQUIRED');
      assert.equal('nextCursor' in blocked.json(), false);
    });
  } finally { await app.close(); await prisma.$disconnect(); }
});
