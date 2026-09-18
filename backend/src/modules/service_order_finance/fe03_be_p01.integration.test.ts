import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { prisma } from '../../core/database/prisma.js';
import { buildApp } from '../../app.js';
import { serviceOrderCustomerRelationshipService } from '../customer_relationship/service_order_customer_relationship.service.js';
import { deliveryPaymentCases } from './delivery_payment.test-cases.js';

// Existing migrations only. Run on a disposable MySQL DB; immutable history is retained until disposal.
test('FE03-BE-P01 MySQL quote privacy and settled delivery gate', { timeout: 240000 }, async t => {
  assert.ok(process.env.DATABASE_URL, 'An isolated disposable MySQL DATABASE_URL is required');
  const priorSecret = process.env.JWT_SECRET;
  process.env.JWT_SECRET = 'fe03-be-p01-test-only';
  const app = buildApp();
  try {
    const org = await prisma.organization.create({ data: { name: `P01 ${randomUUID()}` } });
    const otherOrg = await prisma.organization.create({ data: { name: `Other ${randomUUID()}` } });
    const customer = await prisma.customer.create({ data: { name: 'P01 customer' } });
    const otherCustomer = await prisma.customer.create({ data: { name: 'P01 outsider' } });
    const actor = await prisma.user.create({ data: { name: 'Staff', email: `${randomUUID()}@test.invalid`, passwordHash: 'unused', role: 'ADMIN', status: 'ACTIVE' } });
    const customerUser = await prisma.user.create({ data: { name: 'Customer', email: `${randomUUID()}@test.invalid`, passwordHash: 'unused', role: 'CUSTOMER', status: 'ACTIVE', customerId: customer.id } });
    const outsider = await prisma.user.create({ data: { name: 'Outsider', email: `${randomUUID()}@test.invalid`, passwordHash: 'unused', role: 'CUSTOMER', status: 'ACTIVE', customerId: otherCustomer.id } });
    await prisma.membership.createMany({ data: [org, otherOrg].map(o => ({ userId: actor.id, organizationId: o.id, role: 'ADMIN' })) });
    await prisma.customerOrganization.create({ data: { customerId: customer.id, organizationId: org.id } });
    const equipment = await prisma.equipment.create({ data: { customerId: customer.id, type: 'Computer', brand: 'Test', model: 'P01' } });
    await app.ready();
    const staff = { authorization: `Bearer ${app.jwt.sign({ sub: actor.id, name: actor.name, role: 'ADMIN', organizationId: org.id, customerId: null })}` };
    const otherStaff = { authorization: `Bearer ${app.jwt.sign({ sub: actor.id, name: actor.name, role: 'ADMIN', organizationId: otherOrg.id, customerId: null })}` };
    const customerHeaders = (user = customerUser) => ({ authorization: `Bearer ${app.jwt.sign({ sub: user.id, name: user.name, role: 'CUSTOMER', organizationId: null, customerId: user.customerId })}` });
    const command = (id: string, suffix: string, body = {}, operationId = randomUUID(), headers = staff) =>
      app.inject({ method: 'POST', url: `/api/v1/service-orders/${id}/${suffix}`, headers: { ...headers, 'x-operation-id': operationId }, payload: body });
    async function waiting() {
      const order = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id,
        equipmentId: equipment.id, status: 'DIAGNOSTICO', problemDescription: 'P01', diagnosis: 'Exact quote', totalAmount: '24.68',
        items: { create: [{ description: 'Labor', quantity: 2, unitPrice: '12.34', totalPrice: '24.68' }] } } });
      const published = await command(order.id, 'quotes/publish', { changeReason: 'Initial quote' });
      assert.equal(published.statusCode, 201, published.body);
      return { id: order.id, quoteRevisionId: published.json().quoteRevision.id as string };
    }
    async function ready() {
      const order = await waiting();
      const approval = await command(order.id, 'quote-decision', { quoteRevisionId: order.quoteRevisionId, decision: 'APPROVE' }, randomUUID(), customerHeaders());
      assert.equal(approval.statusCode, 200, approval.body);
      const response = await command(order.id, 'mark-ready');
      assert.equal(response.statusCode, 201, response.body);
      return order;
    }
    async function pay(id: string, amountMinor = 2468) {
      const created = await app.inject({ method: 'POST', url: '/api/v1/payments', headers: { ...staff, 'x-operation-id': randomUUID() },
        payload: { serviceOrderId: id, amountMinor, method: 'PIX' } });
      assert.equal(created.statusCode, 201, created.body);
      const confirmed = await app.inject({ method: 'PATCH', url: `/api/v1/payments/${created.json().payment.id}/status`,
        headers: { ...staff, 'x-operation-id': randomUUID() }, payload: { status: 'CONFIRMED' } });
      assert.equal(confirmed.statusCode, 200, confirmed.body);
    }
    await t.test('actionable quote is exact and minimized; ownership and staff exclusion hold', async () => {
      const order = await waiting();
      const url = `/api/v1/service-orders/${order.id}/customer-quote`;
      const response = await app.inject({ method: 'GET', url, headers: customerHeaders() });
      assert.equal(response.statusCode, 200, response.body);
      assert.deepEqual(response.json(), { serviceOrderId: order.id, quote: { quoteRevisionId: order.quoteRevisionId,
        revisionNumber: 1, decisionMode: 'INITIAL_APPROVAL', diagnosis: 'Exact quote',
        items: [{ description: 'Labor', quantity: 2, unitPriceMinor: 1234, totalPriceMinor: 2468 }],
        totalAmountMinor: 2468, changeReason: 'Initial quote', createdAt: response.json().quote.createdAt } });
      assert.equal((await app.inject({ method: 'GET', url, headers: customerHeaders(outsider) })).statusCode, 404);
      assert.equal((await app.inject({ method: 'GET', url, headers: staff })).statusCode, 403);
      const operationId = randomUUID(), input = { quoteRevisionId: order.quoteRevisionId, decision: 'APPROVE' };
      const first = await command(order.id, 'quote-decision', input, operationId, customerHeaders());
      assert.equal(first.statusCode, 200, first.body);
      const stored = await prisma.operationIdempotency.findUniqueOrThrow({ where: { operationId } });
      const replay = await command(order.id, 'quote-decision', input, operationId, customerHeaders());
      assert.deepEqual(replay.json(), first.json());
      assert.deepEqual(Object.keys(first.json()).sort(), ['quoteDecision', 'serviceOrderId', 'status']);
      assert.deepEqual(Object.keys(first.json().quoteDecision).sort(), ['decidedAt', 'decision', 'quoteRevisionId', 'reason']);
      assert.deepEqual(await prisma.operationIdempotency.findUniqueOrThrow({ where: { operationId } }), stored);
      const decided = await app.inject({ method: 'GET', url, headers: customerHeaders() });
      assert.equal(decided.statusCode, 409);
      assert.ok(decided.body.includes('QUOTE_REVISION_ALREADY_DECIDED'), decided.body);
      const projection = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers: customerHeaders() });
      assert.equal(projection.statusCode, 200, projection.body);
      assert.equal('currentQuoteRevisionId' in projection.json(), false);
    });
    await t.test('initial rejection reports already decided before nonactionable status; ownership still wins', async () => {
      const order = await waiting();
      assert.equal((await command(order.id, 'quote-decision', { quoteRevisionId: order.quoteRevisionId, decision: 'REJECT' },
        randomUUID(), customerHeaders())).statusCode, 200);
      const url = `/api/v1/service-orders/${order.id}/customer-quote`;
      const decided = await app.inject({ method: 'GET', url, headers: customerHeaders() });
      assert.equal(decided.statusCode, 409, decided.body);
      assert.ok(decided.body.includes('QUOTE_REVISION_ALREADY_DECIDED'), decided.body);
      assert.equal((await app.inject({ method: 'GET', url, headers: customerHeaders(outsider) })).statusCode, 404);
      const unpublished = await prisma.serviceOrder.create({ data: { organizationId: org.id, customerId: customer.id,
        equipmentId: equipment.id, status: 'DIAGNOSTICO', problemDescription: 'Unpublished' } });
      const unavailable = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${unpublished.id}/customer-quote`, headers: customerHeaders() });
      assert.equal(unavailable.statusCode, 409, unavailable.body);
      assert.ok(unavailable.body.includes('CUSTOMER_QUOTE_NOT_ACTIONABLE'), unavailable.body);
    });
    await t.test('reapproval presents only the current actionable revision and blocks a decided quote', async () => {
      const order = await waiting();
      assert.equal((await command(order.id, 'quote-decision', { quoteRevisionId: order.quoteRevisionId, decision: 'APPROVE' },
        randomUUID(), customerHeaders())).statusCode, 200);
      const item = await prisma.serviceOrderItem.findFirstOrThrow({ where: { serviceOrderId: order.id } });
      const revised = await command(order.id, 'quotes/revise', { diagnosis: 'Additional repair', changeReason: 'New scope',
        items: [{ id: item.id, description: 'Labor revised', quantity: 2, unitPriceMinor: 1500 }] });
      assert.equal(revised.statusCode, 201, revised.body);
      const revisionId = revised.json().quoteRevision.id;
      const url = `/api/v1/service-orders/${order.id}/customer-quote`;
      const read = await app.inject({ method: 'GET', url, headers: customerHeaders() });
      assert.equal(read.statusCode, 200, read.body);
      assert.equal(read.json().quote.quoteRevisionId, revisionId);
      assert.equal(read.json().quote.decisionMode, 'REAPPROVAL');
      assert.equal(read.json().quote.totalAmountMinor, 3000);
      assert.equal('partId' in read.json().quote.items[0], false);
      assert.equal((await command(order.id, 'quote-decision', { quoteRevisionId: revisionId, decision: 'REJECT', reason: 'Prior scope only' },
        randomUUID(), customerHeaders())).statusCode, 200);
      const decided = await app.inject({ method: 'GET', url, headers: customerHeaders() });
      assert.equal(decided.statusCode, 409, decided.body);
      assert.ok(decided.body.includes('QUOTE_REVISION_ALREADY_DECIDED'));
    });
    await t.test('corrupted quote hash fails closed without publishing internal details', async () => {
      const order = await waiting();
      await prisma.serviceOrderQuoteRevision.update({ where: { id: order.quoteRevisionId }, data: { quoteHash: '0'.repeat(64) } });
      const response = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/customer-quote`, headers: customerHeaders() });
      assert.equal(response.statusCode, 409, response.body);
      assert.ok(response.body.includes('CUSTOMER_QUOTE_HISTORY_INVALID'));
      assert.equal(response.body.includes('quoteHash'), false);
    });
    await t.test('unpaid, partial, wrong tenant, CUSTOMER and generic writers cannot deliver', async () => {
      const order = await ready();
      const op = randomUUID();
      const unpaid = await command(order.id, 'mark-delivered', {}, op);
      assert.equal(unpaid.statusCode, 409, unpaid.body);
      assert.equal(unpaid.json().error, 'DELIVERY_REQUIRES_SETTLED_RECEIVABLE');
      assert.equal((await command(order.id, 'mark-delivered', {}, randomUUID(), otherStaff)).statusCode, 404);
      assert.equal((await command(order.id, 'mark-delivered', {}, randomUUID(), customerHeaders())).statusCode, 403);
      const generic = await app.inject({ method: 'PATCH', url: `/api/v1/service-orders/${order.id}/status`, headers: staff, payload: { newStatus: 'ENTREGUE' } });
      assert.equal(generic.statusCode, 409, generic.body);
      const sync = await app.inject({ method: 'POST', url: '/api/v1/sync/push', headers: staff, payload: { entries: [{
        operationId: randomUUID(), entityId: order.id, entityType: 'SERVICE_ORDER', operationType: 'UPDATE',
        payload: { status: 'ENTREGUE' }, createdAt: new Date().toISOString(),
      }] } });
      assert.equal(sync.json().results[0].status, 'FAILED', sync.body);
      await pay(order.id, 1234);
      assert.equal((await command(order.id, 'mark-delivered')).json().error, 'DELIVERY_REQUIRES_SETTLED_RECEIVABLE');
      await pay(order.id, 1234);
      assert.deepEqual((await command(order.id, 'mark-delivered', {}, op)).json(), unpaid.json(), 'Persisted failure must replay even after payment');
      const deliveryOp = randomUUID();
      const delivered = await command(order.id, 'mark-delivered', {}, deliveryOp);
      assert.equal(delivered.statusCode, 200, delivered.body);
      assert.deepEqual((await command(order.id, 'mark-delivered', {}, deliveryOp)).json(), delivered.json());
      assert.equal((await command(order.id, 'mark-delivered', { notes: 'Changed intent' }, deliveryOp)).statusCode, 409);
      assert.equal(await prisma.serviceOrderStatusHistory.count({ where: { serviceOrderId: order.id, newStatus: 'ENTREGUE' } }), 1);
      assert.equal(await prisma.customerEvent.count({ where: { serviceOrderId: order.id, type: 'SERVICE_ORDER_COMPLETED' } }), 1);
      assert.equal(await prisma.financialAuditEvent.count({ where: { serviceOrderId: order.id, eventType: 'SERVICE_ORDER_DELIVERED' } }), 1);
      const projection = await app.inject({ method: 'GET', url: `/api/v1/service-orders/${order.id}/projection`, headers: staff });
      assert.equal(projection.json().status, 'ENTREGUE');
      assert.equal(projection.json().totalAmountMinor, 2468);
    });
    // Corrupt fixtures only inside this disposable gate; never repair production history.
    for (const scenario of deliveryPaymentCases(actor.id)) await t.test(`MySQL settled graph with ${scenario.name}`, async () => {
      const order = await ready(); await pay(order.id);
      const payment = await prisma.payment.findFirstOrThrow({ where: { serviceOrderId: order.id } });
      if (scenario.allocated) await prisma.payment.update({ where: { id: payment.id }, data: scenario.data });
      else await prisma.payment.create({ data: { organizationId: org.id, customerId: customer.id, serviceOrderId: order.id,
        clientOperationId: randomUUID(), method: 'PIX', createdByUserId: actor.id, ...scenario.data } });
      const changesBefore = await prisma.syncChangeLog.count({ where: { entityId: order.id } });
      const operationId = randomUUID();
      const response = await command(order.id, 'mark-delivered', {}, operationId);
      assert.equal(response.statusCode, scenario.valid ? 200 : 409, response.body);
      const delivered = scenario.valid ? 1 : 0;
      if (!scenario.valid) {
        assert.equal(response.json().error, 'DELIVERY_FINANCIAL_INTEGRITY_INVALID');
        assert.deepEqual((await command(order.id, 'mark-delivered', {}, operationId)).json(), response.json());
        assert.equal(await prisma.syncChangeLog.count({ where: { entityId: order.id } }), changesBefore);
      }
      assert.equal((await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id } })).status, scenario.valid ? 'ENTREGUE' : 'PRONTO');
      assert.equal(await prisma.serviceOrderStatusHistory.count({ where: { serviceOrderId: order.id, newStatus: 'ENTREGUE' } }), delivered);
      assert.equal(await prisma.customerEvent.count({ where: { serviceOrderId: order.id, type: 'SERVICE_ORDER_COMPLETED' } }), delivered);
      assert.equal(await prisma.financialAuditEvent.count({ where: { serviceOrderId: order.id, eventType: 'SERVICE_ORDER_DELIVERED' } }), delivered);
    });
    await t.test('concurrent delivery intents commit exactly once', async () => {
      const order = await ready(); await pay(order.id);
      const results = await Promise.all([command(order.id, 'mark-delivered'), command(order.id, 'mark-delivered')]);
      assert.deepEqual(results.map(r => r.statusCode).sort(), [200, 409]);
      assert.equal(await prisma.financialAuditEvent.count({ where: { serviceOrderId: order.id, eventType: 'SERVICE_ORDER_DELIVERED' } }), 1);
    });
    await t.test('transaction rolls back status/history/audit when CRM fails', async () => {
      const order = await ready(); await pay(order.id);
      const before = await prisma.syncChangeLog.count({ where: { entityId: order.id } });
      const mock = t.mock.method(serviceOrderCustomerRelationshipService, 'registerStatusTransition', async () => { throw new Error('Injected CRM failure'); });
      try {
        assert.equal((await command(order.id, 'mark-delivered')).statusCode, 500);
      } finally { mock.mock.restore(); }
      assert.equal((await prisma.serviceOrder.findUniqueOrThrow({ where: { id: order.id } })).status, 'PRONTO');
      assert.equal(await prisma.serviceOrderStatusHistory.count({ where: { serviceOrderId: order.id, newStatus: 'ENTREGUE' } }), 0);
      assert.equal(await prisma.financialAuditEvent.count({ where: { serviceOrderId: order.id, eventType: 'SERVICE_ORDER_DELIVERED' } }), 0);
      assert.equal(await prisma.syncChangeLog.count({ where: { entityId: order.id } }), before);
    });
    await t.test('stale live membership denies delivery before idempotency reservation', async () => {
      const order = await ready(), operationId = randomUUID();
      await prisma.membership.delete({ where: { userId_organizationId: { userId: actor.id, organizationId: org.id } } });
      const response = await command(order.id, 'mark-delivered', {}, operationId);
      assert.ok([401, 403].includes(response.statusCode), response.body);
      assert.equal(await prisma.operationIdempotency.count({ where: { operationId } }), 0);
    });
  } finally {
    await app.close(); await prisma.$disconnect();
    if (priorSecret === undefined) delete process.env.JWT_SECRET; else process.env.JWT_SECRET = priorSecret;
  }
});
