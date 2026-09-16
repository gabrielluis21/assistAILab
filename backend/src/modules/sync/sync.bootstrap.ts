import { randomBytes } from 'node:crypto';
import { z } from 'zod';
import type { FastifyRequest } from 'fastify';
import { syncRead } from '../../core/database/sync_transaction.js';
import { syncMac, verifySyncMac } from '../../core/sync/sync_integrity.js';
import { ConflictError } from '../../core/utils/errors.js';
import { assertSyncPrincipal, customerScope, equipmentScope, orderScope, readProjection, type ProjectionRecord, type SyncPrincipal } from './sync.projection.js';
import { revisionSchema } from './sync.schema.js';

export function principalScope(principal: SyncPrincipal) {
  return { principalId: principal.sub, role: principal.role, organizationId: principal.organizationId, customerId: principal.customerId };
}
const proofSchema = z.object({
  contractVersion: z.literal(2), bootstrapCursor: revisionSchema,
  principalId: z.string().uuid(), role: z.enum(['CUSTOMER', 'ADMIN', 'TECHNICIAN']),
  organizationId: z.string().uuid().nullable(), customerId: z.string().uuid().nullable(),
  nonce: z.string(), expiresAt: z.number().int().safe(),
}).strict();
export function issueBootstrapProof(principal: SyncPrincipal, bootstrapCursor: string, now = Date.now()): string {
  const claims = { ...principalScope(principal), contractVersion: 2, bootstrapCursor,
    nonce: randomBytes(24).toString('base64url'), expiresAt: now + 24 * 60 * 60 * 1000 };
  return `${Buffer.from(JSON.stringify(claims)).toString('base64url')}.${syncMac('bootstrap-proof', claims)}`;
}
export function verifyBootstrapProof(proof: unknown, principal: SyncPrincipal, now = Date.now()) {
  try {
    if (typeof proof !== 'string' || proof.length > 2048) throw new Error();
    const pieces = proof.split('.');
    if (pieces.length !== 2 || !/^[A-Za-z0-9_-]+$/.test(pieces[0])) throw new Error();
    const claims = proofSchema.parse(JSON.parse(Buffer.from(pieces[0], 'base64url').toString('utf8')));
    if (!verifySyncMac('bootstrap-proof', claims, pieces[1]) || claims.expiresAt <= now ||
        JSON.stringify(principalScope(principal)) !== JSON.stringify({ principalId: claims.principalId, role: claims.role, organizationId: claims.organizationId, customerId: claims.customerId })) throw new Error();
    return claims;
  } catch { throw new ConflictError('SYNC_V2_BOOTSTRAP_REQUIRED'); }
}
export function bootstrapProofHeader(request: FastifyRequest): string | undefined {
  const value = request.headers['x-sync-bootstrap-proof'];
  if (Array.isArray(value) || (typeof value === 'string' && value.includes(','))) throw new ConflictError('SYNC_V2_BOOTSTRAP_REQUIRED');
  return value;
}

type Snapshot = { scope: string; principal: SyncPrincipal; cursor: string; records: ProjectionRecord[];
  pageSize: number; expiresAt: number; bytes: number; tokens: string[]; proof?: string };
type Page = { snapshot: Snapshot; index: number };
/** Materialized bounded snapshots: continuation survives HTTP retries, never a
 * partial activation. Restart/eviction returns an explicit restart requirement.
 * Use sticky routing for bootstrap pages in a multi-worker deployment. */
export class BootstrapStore {
  private pages = new Map<string, Page>();
  private snapshots = new Set<Snapshot>();
  constructor(private readonly ttlMs = 5 * 60_000, private readonly maxBytes = 64 * 1024 * 1024) {}
  private sweep(now: number) {
    for (const snapshot of this.snapshots) if (snapshot.expiresAt <= now) this.remove(snapshot);
  }
  private remove(snapshot: Snapshot) {
    snapshot.tokens.forEach(token => this.pages.delete(token)); this.snapshots.delete(snapshot);
  }
  begin(principal: SyncPrincipal, cursor: string, records: ProjectionRecord[], pageSize: number, now = Date.now()) {
    this.sweep(now);
    const scope = JSON.stringify(principalScope(principal));
    const bytes = Buffer.byteLength(JSON.stringify(records));
    if (bytes > 16 * 1024 * 1024) throw new ConflictError('SYNC_BOOTSTRAP_SNAPSHOT_TOO_LARGE');
    for (const snapshot of this.snapshots) if (snapshot.scope === scope) this.remove(snapshot);
    if (Array.from(this.snapshots).reduce((sum, snapshot) => sum + snapshot.bytes, bytes) > this.maxBytes) throw new ConflictError('SYNC_BOOTSTRAP_CAPACITY_RETRY');
    const snapshot: Snapshot = { scope, principal, cursor, records, pageSize, expiresAt: now + this.ttlMs, bytes, tokens: [] };
    this.snapshots.add(snapshot);
    return this.render(snapshot, 0, now);
  }
  next(principal: SyncPrincipal, token: string, pageSize: number, now = Date.now()) {
    this.sweep(now);
    const page = this.pages.get(token);
    if (!page || page.snapshot.scope !== JSON.stringify(principalScope(principal)) || page.snapshot.pageSize !== pageSize) {
      throw new ConflictError('SYNC_BOOTSTRAP_RESTART_REQUIRED');
    }
    return this.render(page.snapshot, page.index, now);
  }
  private render(snapshot: Snapshot, index: number, now: number) {
    const end = Math.min(index + snapshot.pageSize, snapshot.records.length);
    const complete = end === snapshot.records.length;
    let continuationToken: string | null = null;
    if (!complete) {
      const slot = end / snapshot.pageSize - 1;
      continuationToken = snapshot.tokens[slot] ?? randomBytes(32).toString('base64url');
      snapshot.tokens[slot] = continuationToken;
      this.pages.set(continuationToken, { snapshot, index: end });
    } else snapshot.proof ??= issueBootstrapProof(snapshot.principal, snapshot.cursor, now);
    return { contractVersion: 2, bootstrapCursor: snapshot.cursor, records: snapshot.records.slice(index, end),
      complete, continuationToken, bootstrapProof: complete ? snapshot.proof! : null };
  }
}
export const bootstrapStore = new BootstrapStore();
export async function captureBootstrap(principal: SyncPrincipal) {
  return syncRead(async (tx, revision) => {
    await assertSyncPrincipal(tx, principal);
    const groups = [
      ['CUSTOMER', await tx.customer.findMany({ where: customerScope(principal), select: { id: true }, orderBy: { id: 'asc' } })],
      ['EQUIPMENT', await tx.equipment.findMany({ where: equipmentScope(principal), select: { id: true }, orderBy: { id: 'asc' } })],
      ['SERVICE_ORDER', await tx.serviceOrder.findMany({ where: orderScope(principal), select: { id: true }, orderBy: { id: 'asc' } })],
      ['PAYMENT', principal.role === 'CUSTOMER' ? [] : await tx.payment.findMany({ where: { organizationId: principal.organizationId!, serviceOrder: { financeCoreVersion: null } }, select: { id: true }, orderBy: { id: 'asc' } })],
    ] as const;
    const records: ProjectionRecord[] = [];
    let bytes = 0;
    for (const [type, rows] of groups) for (const row of rows) {
      let record: ProjectionRecord | null;
      try { record = await readProjection(tx, principal, type, row.id, revision, 2); }
      catch { throw new ConflictError('SYNC_V2_REFRESH_REQUIRED'); }
      if (!record) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
      bytes += Buffer.byteLength(JSON.stringify(record));
      if (bytes > 16 * 1024 * 1024) throw new ConflictError('SYNC_BOOTSTRAP_SNAPSHOT_TOO_LARGE');
      records.push(record);
    }
    return { revision, records };
  });
}
