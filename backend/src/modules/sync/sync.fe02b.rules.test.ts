import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { Prisma } from '@prisma/client';
import { legacyMoneyToMinor, decimalToMinorUnits, minorUnitsToDecimalText, lineTotalMinor, aggregateTotalMinor, DECIMAL_10_2_MAX_MINOR, DECIMAL_14_2_MAX_MINOR } from '../../core/money/money.js';
import { normalizeSyncEntry, revisionSchema } from './sync.schema.js';
import { syncOperationHash, trustedChangeMetadata } from './sync.controller.js';
import { BootstrapStore, issueBootstrapProof, verifyBootstrapProof } from './sync.bootstrap.js';
import { serializeStaffOrder, serializeCustomerOrder, type OrderAggregate } from './sync.projection.js';
import { isGenericFinanceSyncPushBlocked, isGenericSyncPullTypeAllowed } from './sync.fin-f02.rules.js';
import { computeCanonicalHash } from '../../core/idempotency/canonical_json.js';
import { approvedQuoteAuthorityFromRevision } from '../service_order_finance/mark_ready.rules.js';
import { syncMac } from '../../core/sync/sync_integrity.js';
import { assertCustomerOrderPrivacy } from './sync.customer-projection.test-helpers.js';

process.env.JWT_SECRET = 'fe02b-unit-only-secret';
const principal = { sub: randomUUID(), role: 'ADMIN' as const, organizationId: randomUUID(), customerId: null, name: 'Staff' };
const parentId = randomUUID();
const entry = (payload: Record<string, unknown>, type = 'SERVICE_ORDER_ITEM', operationType: 'CREATE' | 'UPDATE' | 'DELETE' = 'CREATE') => ({
  operationId: randomUUID(), entityType: type, entityId: randomUUID(), operationType, payload, createdAt: '2026-09-15T00:00:00Z',
});
const validItem = { serviceOrderId: parentId, description: 'Labor', quantity: 2, unitPriceMinor: 1234 };
for (const bad of [-1, -0, 1.001, 0.1 + 0.2, NaN, Infinity, null, undefined, '', ' 1.00', '1e2', '01.00', '-0', '1.', '1.000', {}, '9'.repeat(10000)]) {
  test(`v1 rejects ambiguous/invalid money ${String(bad).slice(0, 35)}`, () => assert.throws(() => legacyMoneyToMinor(bad)));
}
test('money text and Decimal preserve exact boundaries and reject overflow before Number', () => {
  for (const minor of [0, 1, 29, DECIMAL_10_2_MAX_MINOR, DECIMAL_14_2_MAX_MINOR]) {
    const text = minorUnitsToDecimalText(minor);
    assert.equal(decimalToMinorUnits(new Prisma.Decimal(text)), minor);
    assert.equal(legacyMoneyToMinor(text, DECIMAL_14_2_MAX_MINOR), minor);
  }
  assert.throws(() => legacyMoneyToMinor('100000000.00'));
  assert.throws(() => decimalToMinorUnits(new Prisma.Decimal('1.001')));
  assert.throws(() => decimalToMinorUnits(new Prisma.Decimal('999999999999.999')));
  assert.throws(() => lineTotalMinor(2_147_483_648, 0));
  assert.throws(() => aggregateTotalMinor([{ quantity: 1, unitPriceMinor: DECIMAL_10_2_MAX_MINOR }, { quantity: 1, unitPriceMinor: 1 }]));
});
for (const field of ['unitPrice', 'totalPrice', 'totalPriceMinor', 'totalAmount', 'totalAmountMinor', 'costPrice', 'price', 'unit_price', 'financeCoreVersion']) {
  test(`strict v2 rejects ${field}`, () => assert.throws(() => normalizeSyncEntry(entry({ ...validItem, [field]: 1 }), 2)));
}
test('strict money schemas distinguish CREATE UPDATE DELETE and reject missing money, aliases and unknowns', () => {
  const { unitPriceMinor, ...missing } = validItem;
  assert.throws(() => normalizeSyncEntry(entry(missing), 2));
  assert.throws(() => normalizeSyncEntry(entry({ ...validItem, quantity: 0 }), 2));
  assert.throws(() => normalizeSyncEntry(entry({ ...validItem, quantity: 2_147_483_648 }), 2));
  assert.throws(() => normalizeSyncEntry(entry({ ...validItem, unitPrice: '12.34' }), 1));
  assert.throws(() => normalizeSyncEntry(entry({ ...missing, service_order_id: parentId, unitPrice: '12.34' }), 1));
  assert.deepEqual(normalizeSyncEntry(entry({}, 'SERVICE_ORDER_ITEM', 'UPDATE'), 2).payload, {});
  assert.throws(() => normalizeSyncEntry(entry(validItem, 'SERVICE_ORDER_ITEM', 'DELETE'), 2));
  const v1 = normalizeSyncEntry(entry({ ...missing, unitPrice: '12.34', totalPrice: '24.68' }), 1);
  assert.equal(v1.payload.unitPriceMinor, 1234);
  assert.equal(v1.assertions.totalPriceMinor, 2468);
  assert.equal('totalPriceMinor' in v1.payload, false);
  assert.throws(() => normalizeSyncEntry(entry({ totalAmountMinor: 0 }, 'SERVICE_ORDER', 'UPDATE'), 2));
});
test('idempotency binds protocol, normalized entity type, entity ID and operation', () => {
  const original = normalizeSyncEntry(entry(validItem), 2);
  const hash = syncOperationHash(original, 2);
  for (const changed of [{ ...original, entityId: randomUUID() }, { ...original, entityType: 'SERVICE_ORDER' }, { ...original, operationType: 'UPDATE' as const }]) {
    assert.notEqual(syncOperationHash(changed, 2), hash);
  }
  assert.notEqual(syncOperationHash(original, 1), hash);
  assert.equal(syncOperationHash(normalizeSyncEntry({ ...original, entityType: 'service_order_item' }, 2), 2), hash);
});
test('PART has no generic authority in either role or version', () => {
  assert.equal(isGenericFinanceSyncPushBlocked('part'), true);
  for (const role of ['ADMIN', 'TECHNICIAN', 'CUSTOMER']) assert.equal(isGenericSyncPullTypeAllowed({ entityType: 'PART', role, isAuthorizedLegacyPayment: true }), false);
});
test('bootstrap proof is principal/scope/protocol/cursor bound, authenticated and expires', () => {
  const proof = issueBootstrapProof(principal, '9007199254740993', 1000);
  assert.equal(verifyBootstrapProof(proof, principal, 1001).bootstrapCursor, '9007199254740993');
  for (const altered of [{ ...principal, sub: randomUUID() }, { ...principal, organizationId: randomUUID() }, { ...principal, role: 'TECHNICIAN' as const }]) {
    assert.throws(() => verifyBootstrapProof(proof, altered, 1001));
  }
  const [encoded, signature] = proof.split('.');
  const claims = JSON.parse(Buffer.from(encoded, 'base64url').toString());
  for (const alteration of [{ contractVersion: 1 }, { bootstrapCursor: '9999999999999999999' }]) {
    assert.throws(() => verifyBootstrapProof(`${Buffer.from(JSON.stringify({ ...claims, ...alteration })).toString('base64url')}.${signature}`, principal, 1001));
  }
  assert.throws(() => verifyBootstrapProof(proof, principal, 1000 + 24 * 60 * 60 * 1000));
  assert.throws(() => verifyBootstrapProof(undefined, principal));
});
test('bootstrap requires ordered issued continuations, stable pages, retry and complete traversal', () => {
  const store = new BootstrapStore(10000);
  const records = Array.from({ length: 5 }, (_, n) => ({ entityType: 'CUSTOMER', entityId: String(n), data: { id: String(n) } }));
  const first = store.begin(principal, '99', records, 2, 100);
  assert.equal(first.bootstrapProof, null);
  assert.throws(() => store.next(principal, 'last-page', 2, 101));
  assert.throws(() => store.next({ ...principal, sub: randomUUID() }, first.continuationToken!, 2, 101));
  assert.throws(() => store.next(principal, first.continuationToken!, 100, 101));
  const second = store.next(principal, first.continuationToken!, 2, 101);
  assert.equal(second.bootstrapProof, null);
  assert.deepEqual(second, store.next(principal, first.continuationToken!, 2, 102));
  const final = store.next(principal, second.continuationToken!, 2, 103);
  assert.equal(final.complete, true);
  assert.equal(final.continuationToken, null);
  assert.equal(verifyBootstrapProof(final.bootstrapProof, principal, 104).bootstrapCursor, '99');
  assert.deepEqual([...first.records, ...second.records, ...final.records], records);
  assert.throws(() => store.next(principal, second.continuationToken!, 2, 10100));
});
test('bootstrap capacity cannot return a partial activation and empty snapshot completes', () => {
  const store = new BootstrapStore(10000, 1);
  assert.throws(() => store.begin(principal, '1', [{ entityType: 'CUSTOMER', entityId: '1', data: {} }], 1));
  assert.equal(new BootstrapStore().begin(principal, '0', [], 1).complete, true);
});
test('projection revisions use canonical decimal BigInt syntax, never lexical/Number ordering', () => {
  for (const bad of ['-1', '01', '1.0', '1e3', ' 1', '+1']) assert.throws(() => revisionSchema.parse(bad));
  const larger = revisionSchema.parse('9007199254740993');
  assert.ok(BigInt(larger) > 9007199254740992n);
  assert.ok(BigInt('10') > BigInt('9'));
});
function fixture() {
  const date = new Date('2026-09-15T00:00:00Z');
  const item = { id: randomUUID(), serviceOrderId: parentId, partId: null, description: 'Labor', quantity: 2,
    unitPrice: new Prisma.Decimal('12.34'), totalPrice: new Prisma.Decimal('24.68'), createdAt: date };
  return { id: parentId, friendlyId: 7, organizationId: principal.organizationId, customerId: randomUUID(), equipmentId: randomUUID(),
    technicianId: principal.sub, financeCoreVersion: 2, status: 'AGUARDANDO_REAPROVACAO', diagnosis: 'Diagnosis', solution: null,
    problemDescription: 'Problem', totalAmount: new Prisma.Decimal('24.68'), createdAt: date, updatedAt: date,
    currentQuoteRevisionId: null, lastApprovedQuoteRevisionId: null, currentQuoteRevision: null, lastApprovedQuoteRevision: null, items: [item],
  } as OrderAggregate;
}
function quote(order: OrderAggregate, version: number) {
  const serviceItemsSnapshot = order.items.map(i => ({ id: i.id, partId: i.partId, description: i.description, quantity: i.quantity, unitPrice: '12.34', totalPrice: '24.68' }));
  const quoteSnapshot = { snapshotVersion: version, serviceOrderId: order.id, organizationId: order.organizationId, customerId: order.customerId,
    diagnosis: order.diagnosis, totalAmount: '24.68', serviceItems: serviceItemsSnapshot, parts: [] };
  return { id: randomUUID(), serviceOrderId: order.id, organizationId: order.organizationId, customerId: order.customerId,
    diagnosisSnapshot: order.diagnosis, totalAmount: order.totalAmount, serviceItemsSnapshot, quoteSnapshot,
    createdAt: new Date(), createdByUserId: principal.sub, revisionNumber: 1, partsSnapshot: [], changeType: 'INITIAL', changeReason: null,
    quoteHash: computeCanonicalHash(quoteSnapshot) } as NonNullable<OrderAggregate['currentQuoteRevision']>;
}
test('immutable v1 and new v2 quote readers validate identity, hash and complete line aggregate', () => {
  for (const version of [1, 2]) {
    const revision = quote(fixture(), version);
    const before = JSON.stringify(revision);
    assert.equal(approvedQuoteAuthorityFromRevision(revision).commercialScope.totalAmountMinor, 2468);
    assert.equal(JSON.stringify(revision), before);
    assert.throws(() => approvedQuoteAuthorityFromRevision({ ...revision, quoteHash: 'forged' }));
    assert.throws(() => approvedQuoteAuthorityFromRevision({ ...revision, customerId: randomUUID() }));
  }
  const revision = quote(fixture(), 2);
  const snapshot = { ...(revision.quoteSnapshot as Prisma.JsonObject), parts: [{ name: 'Global part', price: '1.00' }] };
  assert.throws(() => approvedQuoteAuthorityFromRevision({ ...revision, quoteSnapshot: snapshot, quoteHash: computeCanonicalHash(snapshot) }));
});
test('materialization is proven by scope equality, never status, and resume preserves current pointer', () => {
  const order = fixture();
  assert.equal(serializeStaffOrder(order, '9').commercialScopeSource, 'UNPUBLISHED');
  const approved = quote(order, 1);
  const current = quote({ ...order, diagnosis: 'New diagnosis' }, 2);
  Object.assign(order, { currentQuoteRevision: current, currentQuoteRevisionId: current.id, lastApprovedQuoteRevision: approved, lastApprovedQuoteRevisionId: approved.id });
  const resumed = serializeStaffOrder(order, '10');
  assert.equal(resumed.materializedQuoteRevisionId, approved.id);
  assert.equal(resumed.commercialScopeSource, 'LAST_APPROVED_QUOTE');
  assert.equal(resumed.currentQuoteRevisionId, current.id);
  order.diagnosis = 'New diagnosis';
  assert.equal(serializeStaffOrder(order, '11').materializedQuoteRevisionId, current.id);
  order.diagnosis = 'Neither';
  assert.throws(() => serializeStaffOrder(order, '12'));
});
test('canonical DTO has full items, no major money or finance version and CUSTOMER excludes staff identity', () => {
  const order = fixture();
  const staff = serializeStaffOrder(order, '9007199254740993');
  const customer = serializeCustomerOrder(order, '9007199254740993');
  assert.equal(staff.totalAmountMinor, 2468);
  assert.equal(staff.items[0].totalPriceMinor, 2468);
  assert.equal('financeCoreVersion' in staff, false);
  assert.equal('totalAmount' in staff, false);
  assert.equal('technicianId' in customer, false);
  for (const change of [{ status: 'CANCELADO' }, { diagnosis: 'Other' }, { solution: 'Different' }]) {
    assert.notEqual(computeCanonicalHash({ ...staff, ...change }), computeCanonicalHash(staff));
  }
  assert.throws(() => serializeStaffOrder({ ...order, totalAmount: new Prisma.Decimal('1.00') }, '10'));
});
test('CUSTOMER serializer allowlists commercial values while staff retains internal authority fields', () => {
  const order = fixture();
  order.items[0].partId = randomUUID();
  const revision = quote(order, 2);
  Object.assign(order, { currentQuoteRevision: revision, currentQuoteRevisionId: revision.id,
    lastApprovedQuoteRevision: revision, lastApprovedQuoteRevisionId: revision.id });
  const customer = serializeCustomerOrder(order, '9007199254740993');
  assertCustomerOrderPrivacy(customer);
  assert.deepEqual(customer.items, [{ description: 'Labor', quantity: 2, unitPriceMinor: 1234, totalPriceMinor: 2468 }]);
  assert.equal(customer.diagnosis, order.diagnosis);
  assert.equal(customer.totalAmountMinor, 2468);
  assert.equal(customer.projectionRevision, '9007199254740993');
  const staff = serializeStaffOrder(order, '9007199254740993');
  assert.equal(staff.organizationId, order.organizationId);
  assert.equal(staff.customerId, order.customerId);
  assert.equal(staff.items[0].id, order.items[0].id);
  assert.equal(staff.items[0].partId, order.items[0].partId);
  assert.equal(staff.materializedQuoteRevisionId, revision.id);
});
test('CUSTOMER serializer still rejects corrupt hidden authority and inexact money', () => {
  const order = fixture();
  const revision = quote(order, 2);
  Object.assign(order, { currentQuoteRevision: revision, currentQuoteRevisionId: revision.id });
  assert.throws(() => serializeCustomerOrder({ ...order, totalAmount: new Prisma.Decimal('0.01') }, '1'));
  assert.throws(() => serializeCustomerOrder({ ...order, items: [{ ...order.items[0], totalPrice: new Prisma.Decimal('0.01') }] }, '1'));
  assert.throws(() => serializeCustomerOrder({ ...order, currentQuoteRevisionId: randomUUID() }, '1'));
  assert.throws(() => serializeCustomerOrder({ ...order, currentQuoteRevision: { ...revision, quoteHash: 'forged' } }, '1'));
  assert.throws(() => serializeCustomerOrder({ ...order, currentQuoteRevision: { ...revision, customerId: randomUUID() } }, '1'));
  assert.throws(() => serializeCustomerOrder({ ...order, diagnosis: 'Not the materialized scope' }, '1'));
});
test('historical JSON cannot forge tombstone audience or replay metadata on another event', () => {
  const data = { syncMetadataVersion: 2, audience: { organizationIds: [principal.organizationId], customerIds: [] }, parentId: parentId, relationshipChange: false };
  const change = { id: 55n, entityType: 'SERVICE_ORDER_ITEM', entityId: randomUUID(), operationType: 'DELETE', data, cursor: '55', createdAt: new Date() } as const;
  assert.equal(trustedChangeMetadata(change), null);
  const signature = syncMac('change-metadata', { id: '55', entityType: change.entityType, entityId: change.entityId, operationType: change.operationType, data });
  const signed = { ...change, data: { ...data, metadataMac: signature } };
  assert.equal(trustedChangeMetadata(signed)?.parentId, parentId);
  assert.equal(trustedChangeMetadata({ ...signed, id: 56n }), null);
  assert.equal(trustedChangeMetadata({ ...signed, entityId: randomUUID() }), null);
});
