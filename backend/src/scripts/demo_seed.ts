import assert from 'node:assert/strict';
import bcrypt from 'bcrypt';
import { z } from 'zod';
import { buildApp } from '../app.js';
import { prisma } from '../core/database/prisma.js';
import { syncTransaction } from '../core/database/sync_transaction.js';
import { aggregateTotalMinor } from '../core/money/money.js';
import { assertDemoDatabase, demoId, demoScenarios, seedDemoScenario } from './demo_seed.plan.js';

const accounts = [
  { key: 'admin-a', name: 'Ana — Administradora Demo A', email: 'admin.a@fe02b.demo.test', role: 'ADMIN', tenant: 'a', customer: null },
  { key: 'admin-b', name: 'Bruno — Administrador Demo B', email: 'admin.b@fe02b.demo.test', role: 'ADMIN', tenant: 'b', customer: null },
  { key: 'technician', name: 'Carlos — Técnico Demo A', email: 'tecnico@fe02b.demo.test', role: 'TECHNICIAN', tenant: 'a', customer: null },
  { key: 'joao', name: 'João — Cliente Demo', email: 'joao@fe02b.demo.test', role: 'CUSTOMER', tenant: null, customer: 'joao' },
  { key: 'maria', name: 'Maria — Cliente Demo', email: 'maria@fe02b.demo.test', role: 'CUSTOMER', tenant: null, customer: 'maria' },
] as const;
const bootstrapPage = z.object({
  bootstrapCursor: z.string().regex(/^(0|[1-9][0-9]*)$/), complete: z.boolean(),
  continuationToken: z.string().nullable().optional(), bootstrapProof: z.string().nullable().optional(),
  records: z.array(z.object({ entityType: z.string(), entityId: z.string(), data: z.record(z.unknown()) })),
});

/** Provisions identities only. All commercial mutations below use real routes. */
async function seedIdentities(password: string): Promise<void> {
  const passwordHash = await bcrypt.hash(password, 12);
  await syncTransaction(async tx => {
    for (const tenant of ['a', 'b']) {
      const id = demoId(`organization:${tenant}`);
      if (!await tx.organization.findUnique({ where: { id } })) await tx.organization.create({ data: { id, name: `AssistAiLab Demo ${tenant.toUpperCase()}` } });
    }
    for (const customer of ['joao', 'maria']) {
      const id = demoId(`customer:${customer}`);
      if (!await tx.customer.findUnique({ where: { id } })) await tx.customer.create({ data: { id, name: customer === 'joao' ? 'João — Cliente Demo' : 'Maria — Cliente Demo', email: `${customer}@fe02b.demo.test` } });
    }
    for (const account of accounts) {
      const id = demoId(`user:${account.key}`);
      const customerId = account.customer ? demoId(`customer:${account.customer}`) : null;
      const existing = await tx.user.findUnique({ where: { id } });
      if (existing) {
        assert.equal(existing.email, account.email, 'Demo identity collision');
        assert.equal(existing.role, account.role, 'Demo role changed; do not overwrite it');
        assert.equal(existing.customerId, customerId, 'Demo customer binding changed');
      } else await tx.user.create({ data: { id, name: account.name, email: account.email, role: account.role, status: 'ACTIVE', customerId, passwordHash } });
      if (account.tenant) {
        const organizationId = demoId(`organization:${account.tenant}`);
        const where = { userId_organizationId: { userId: id, organizationId } };
        if (!await tx.membership.findUnique({ where })) await tx.membership.create({ data: { userId: id, organizationId, role: account.role } });
      }
    }
    for (const scenario of demoScenarios) {
      const customerId = demoId(`customer:${scenario.customer}`);
      const organizationId = demoId(`organization:${scenario.tenant}`);
      const where = { customerId_organizationId: { customerId, organizationId } };
      if (!await tx.customerOrganization.findUnique({ where })) await tx.customerOrganization.create({ data: { customerId, organizationId, status: 'ACTIVE' } });
      const id = demoId(`equipment:${scenario.key}`);
      if (!await tx.equipment.findUnique({ where: { id } })) await tx.equipment.create({ data: {
        id, customerId, ownerType: 'CUSTOMER', type: scenario.label.split(' — ')[0], brand: 'Marca fictícia', model: 'Modelo Demo', serialNumber: `FE02B-${scenario.key}`, notes: 'Equipamento fictício para demonstração.',
      } });
    }
  });
}

export async function runDemoSeed() {
  assertDemoDatabase(process.env);
  const password = process.env.SEED_DEMO_PASSWORD ?? 'Demo@123456';
  assert.ok(password.length >= 10, 'SEED_DEMO_PASSWORD must contain at least 10 characters');
  const app = buildApp();
  try {
    await app.ready();
    await seedIdentities(password);
    const headers = Object.fromEntries(accounts.map(account => [account.key, {
      authorization: `Bearer ${app.jwt.sign({ sub: demoId(`user:${account.key}`), name: account.name, role: account.role,
        organizationId: account.tenant ? demoId(`organization:${account.tenant}`) : null,
        customerId: account.customer ? demoId(`customer:${account.customer}`) : null })}`,
    }]));
    async function request(actor: string, method: 'POST' | 'GET', url: string, payload?: Record<string, unknown>, extra: Record<string, string> = {}) {
      const response = await app.inject({ method, url, headers: { ...headers[actor], ...extra }, ...(payload ? { payload } : {}) });
      assert.ok(response.statusCode >= 200 && response.statusCode < 300, `${method} ${url}: ${response.statusCode} ${response.body}`);
      return response.json();
    }
    async function bootstrap(actor: string) {
      let continuationToken: string | undefined;
      let cursor: string | undefined;
      const records: z.infer<typeof bootstrapPage>['records'] = [];
      do {
        const page = bootstrapPage.parse(await request(actor, 'POST', '/api/v1/sync/bootstrap', {
          contractVersion: 2, limit: 3, ...(continuationToken ? { continuationToken } : {}),
        }));
        if (cursor !== undefined) assert.equal(page.bootstrapCursor, cursor);
        cursor = page.bootstrapCursor;
        records.push(...page.records);
        if (page.complete) {
          assert.ok(page.bootstrapProof, 'Complete bootstrap must issue proof');
          return { proof: page.bootstrapProof, cursor, records };
        }
        assert.ok(page.continuationToken, 'Incomplete bootstrap must issue continuation');
        assert.ok(!page.bootstrapProof, 'No proof before traversal completes');
        continuationToken = page.continuationToken;
      } while (true);
    }
    for (const tenant of ['a', 'b']) {
      const staff = `admin-${tenant}`;
      const activation = await bootstrap(staff);
      for (const scenario of demoScenarios.filter(s => s.tenant === tenant)) {
        await seedDemoScenario(scenario, {
          push: async entry => {
            const response = await request(staff, 'POST', '/api/v1/sync/push', { contractVersion: 2, entries: [entry] }, { 'x-sync-bootstrap-proof': activation.proof });
            assert.equal(response.results?.[0]?.status, 'SYNCED', JSON.stringify(response));
          },
          post: (path, payload, operationId, customer) => request(customer ? scenario.customer : staff, 'POST', path, payload, { 'x-operation-id': operationId }),
        });
      }
    }
    const result = [];
    for (const scenario of demoScenarios) {
      const id = demoId(`order:${scenario.key}`);
      const path = `/api/v1/service-orders/${id}/projection`;
      const projection = await request(`admin-${scenario.tenant}`, 'GET', path);
      const customerProjection = await request(scenario.customer, 'GET', path);
      assert.equal(projection.contractVersion, 2);
      assert.match(projection.projectionRevision, /^(0|[1-9][0-9]*)$/);
      assert.equal(projection.totalAmountMinor, aggregateTotalMinor(projection.items));
      assert.deepEqual(customerProjection.items, projection.items);
      assert.equal(customerProjection.totalAmountMinor, projection.totalAmountMinor);
      assert.ok(!Object.hasOwn(customerProjection, 'technicianId'));
      assert.ok(!Object.hasOwn(customerProjection, 'financeCoreVersion'));
      const other = await app.inject({ method: 'GET', url: path, headers: headers[`admin-${scenario.tenant === 'a' ? 'b' : 'a'}`] });
      assert.equal(other.statusCode, 404, 'Other tenant must not see the demo order');
      result.push({ scenario: scenario.key, id, status: projection.status, totalAmountMinor: projection.totalAmountMinor,
        currentQuoteRevisionId: projection.currentQuoteRevisionId, materializedQuoteRevisionId: projection.materializedQuoteRevisionId });
    }
    // Confirm both professional and CUSTOMER projections can complete paginated
    // bootstrap. These process-local proofs are never exported to the Frontend.
    for (const account of accounts) {
      const snapshot = await bootstrap(account.key);
      assert.ok(snapshot.records.every(record => record.entityType !== 'PART'));
      for (const record of snapshot.records.filter(record => record.entityType === 'SERVICE_ORDER')) {
        if (account.tenant) assert.equal(record.data.organizationId, demoId(`organization:${account.tenant}`));
        else assert.equal(record.data.customerId, demoId(`customer:${account.customer}`));
      }
    }
    return { accounts: accounts.map(({ email, role, name }) => ({ email, role, name })), orders: result };
  } finally {
    await app.close();
    await prisma.$disconnect();
  }
}
