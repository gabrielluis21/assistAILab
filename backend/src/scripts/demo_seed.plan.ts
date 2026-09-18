import { createHash } from 'node:crypto';
import { z } from 'zod';
import type { OutboxEntry } from '../modules/sync/sync.schema.js';

// Stable identities enable command replay; changing the dataset requires a new
// namespace, never replacing hashes or deleting historical operation records.
export function demoId(key: string): string {
  const bytes = createHash('sha256').update(`assistailab-fe02b-demo-v1:${key}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 15) | 0x50;
  bytes[8] = (bytes[8] & 63) | 0x80;
  const h = bytes.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

export const demoScenarios = [
  { key: 'diagnosis', label: 'Notebook — diagnóstico', tenant: 'a', customer: 'joao', stage: 'diagnosis' },
  { key: 'waiting', label: 'Celular — aguardando aprovação', tenant: 'a', customer: 'joao', stage: 'waiting' },
  { key: 'executing', label: 'Desktop — em execução', tenant: 'a', customer: 'maria', stage: 'executing' },
  { key: 'ready', label: 'Impressora — pronta / conta a receber', tenant: 'a', customer: 'maria', stage: 'ready' },
  { key: 'delivered', label: 'Notebook — entregue', tenant: 'a', customer: 'joao', stage: 'delivered' },
  { key: 'reapproval', label: 'Tablet — aguardando reaprovação', tenant: 'a', customer: 'joao', stage: 'reapproval' },
  { key: 'rejected', label: 'Desktop — revisão rejeitada', tenant: 'a', customer: 'maria', stage: 'rejected' },
  { key: 'resumed', label: 'Celular — escopo aprovado retomado', tenant: 'a', customer: 'maria', stage: 'resumed' },
  { key: 'other-tenant', label: 'Notebook — outra assistência', tenant: 'b', customer: 'joao', stage: 'waiting' },
] as const;
export type DemoScenario = typeof demoScenarios[number];
export type DemoTransport = {
  push(entry: OutboxEntry): Promise<void>;
  post(path: string, payload: Record<string, unknown>, operationId: string, customer: boolean): Promise<unknown>;
  patch(path: string, payload: Record<string, unknown>, operationId: string): Promise<unknown>;
};

const quoteResult = z.object({ quoteRevision: z.object({ id: z.string().uuid() }) });

export async function seedDemoScenario(scenario: DemoScenario, transport: DemoTransport): Promise<void> {
  const orderId = demoId(`order:${scenario.key}`);
  const op = (step: string) => demoId(`operation:${scenario.key}:${step}`);
  const push = (step: string, entityType: string, entityId: string, payload: Record<string, unknown>, operationType: 'CREATE' | 'UPDATE' = 'CREATE') => transport.push({
    operationId: op(step), entityType, entityId, operationType, payload, createdAt: '2026-09-16T00:00:00Z',
  });
  const post = (step: string, suffix: string, payload: Record<string, unknown>, customer = false) =>
    transport.post(`/api/v1/service-orders/${orderId}/${suffix}`, payload, op(step), customer);
  await push('create', 'SERVICE_ORDER', orderId, {
    customerId: demoId(`customer:${scenario.customer}`), equipmentId: demoId(`equipment:${scenario.key}`),
    technicianId: demoId(`user:${scenario.tenant === 'a' ? 'technician' : 'admin-b'}`),
    problemDescription: `[DEMO FE-02B] ${scenario.label}`,
    diagnosis: 'Falha reproduzida em bancada. Limpeza e reparo dos conectores necessários.',
  });
  await push('labor', 'SERVICE_ORDER_ITEM', demoId(`item:${scenario.key}:labor`), {
    serviceOrderId: orderId, description: 'Diagnóstico e reparo em bancada', quantity: 1, unitPriceMinor: 15000,
  });
  await push('connectors', 'SERVICE_ORDER_ITEM', demoId(`item:${scenario.key}:connectors`), {
    serviceOrderId: orderId, description: 'Reparo de conector — serviço sem vínculo ao catálogo', quantity: 2, unitPriceMinor: 4590,
  });
  if (scenario.stage === 'diagnosis') return;
  const initial = quoteResult.parse(await post('publish', 'quotes/publish', { changeReason: 'Orçamento inicial da demonstração FE-02B' }));
  if (scenario.stage === 'waiting') return;
  await post('approve', 'quote-decision', { quoteRevisionId: initial.quoteRevision.id, decision: 'APPROVE' }, true);
  if (scenario.stage === 'executing') return;
  if (scenario.stage === 'ready' || scenario.stage === 'delivered') {
    await post('ready', 'mark-ready', { notes: 'Reparo concluído e equipamento testado em bancada.' });
    if (scenario.stage === 'delivered') {
      const payment = z.object({ payment: z.object({ id: z.string().uuid() }) }).parse(await transport.post(
        '/api/v1/payments', { serviceOrderId: orderId, amountMinor: 24180, method: 'PIX' }, op('payment-create'), false));
      await transport.patch(`/api/v1/payments/${payment.payment.id}/status`, { status: 'CONFIRMED' }, op('payment-confirm'));
      await post('deliver-settled', 'mark-delivered', {});
    }
    return;
  }
  const revised = quoteResult.parse(await post('revise', 'quotes/revise', {
    diagnosis: 'Inspeção adicional identificou reparo mais complexo nos conectores.',
    changeReason: 'Novo orçamento após desmontagem',
    items: [
      { id: demoId(`item:${scenario.key}:labor`), description: 'Diagnóstico e reparo em bancada', quantity: 1, unitPriceMinor: 15000 },
      { id: demoId(`item:${scenario.key}:connectors`), description: 'Reparo avançado de conector', quantity: 2, unitPriceMinor: 5590 },
    ],
  }));
  if (scenario.stage === 'reapproval') return;
  await post('reject', 'quote-decision', { quoteRevisionId: revised.quoteRevision.id, decision: 'REJECT', reason: 'Prefiro manter o orçamento aprovado anteriormente.' }, true);
  if (scenario.stage === 'resumed') await post('resume', 'quotes/resume-approved-scope', { reason: 'Retomar apenas os serviços já aprovados pelo cliente.' });
}

export function assertDemoDatabase(environment: { NODE_ENV?: string; DATABASE_URL?: string; JWT_SECRET?: string }): void {
  if (environment.NODE_ENV === 'production' || environment.NODE_ENV === 'test') throw new Error('DEMO_SEED_REQUIRES_DEMO_ENVIRONMENT');
  const database = environment.DATABASE_URL ? decodeURIComponent(new URL(environment.DATABASE_URL).pathname).replace(/^\//, '') : '';
  if (database !== 'assistailab_fe02b_demo') throw new Error('DEMO_SEED_REQUIRES_DATABASE_assistailab_fe02b_demo');
  if (!environment.JWT_SECRET) throw new Error('DEMO_SEED_REQUIRES_JWT_SECRET');
}
