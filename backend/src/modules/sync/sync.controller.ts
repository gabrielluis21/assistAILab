import type { FastifyReply, FastifyRequest } from 'fastify';
import { Prisma } from '@prisma/client';
import { ZodError } from 'zod';
import { prisma } from '../../core/database/prisma.js';
import { syncRead, syncTransaction } from '../../core/database/sync_transaction.js';
import { computeCanonicalHash } from '../../core/idempotency/canonical_json.js';
import { IdempotencyService, IdempotencyStateConflictError } from '../../core/idempotency/idempotency.service.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { verifySyncMac } from '../../core/sync/sync_integrity.js';
import { AppError, ConflictError } from '../../core/utils/errors.js';
import { pushSyncSchema, pullSyncQuerySchema, bootstrapSchema, normalizeSyncEntry, type NormalizedEntry } from './sync.schema.js';
import { mutateSyncEntity } from './sync.mutation.js';
import { assertSyncPrincipal, readProjection, type SyncPrincipal } from './sync.projection.js';
import { bootstrapProofHeader, verifyBootstrapProof, captureBootstrap, bootstrapStore } from './sync.bootstrap.js';
import { isGenericFinanceSyncPushBlocked, isGenericSyncPullTypeAllowed } from './sync.fin-f02.rules.js';
export { assertGenericEquipmentSyncPayload } from './sync.mutation.js';

export function syncOperationHash(entry: NormalizedEntry, contractVersion: 1 | 2): string {
  return computeCanonicalHash({ contractVersion, entityType: entry.entityType, entityId: entry.entityId,
    operationType: entry.operationType, payload: entry.payload, assertions: entry.assertions });
}
function domainFailure(error: unknown): string | null {
  if (error instanceof AppError || error instanceof RangeError) return error.message;
  if (error instanceof ZodError) return 'SYNC_PAYLOAD_INVALID';
  if (error instanceof Prisma.PrismaClientKnownRequestError && ['P2002', 'P2003', 'P2025'].includes(error.code)) return 'SYNC_ENTITY_CONFLICT';
  return null;
}

export async function pushSyncHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = pushSyncSchema.parse(request.body);
  const principal = getAuthUser(request);
  if (body.contractVersion === 2) verifyBootstrapProof(bootstrapProofHeader(request), principal);
  const results: Prisma.InputJsonValue[] = [];
  const idempotency = new IdempotencyService(prisma);
  for (const raw of body.entries) {
    const type = raw.entityType.toUpperCase();
    if (isGenericFinanceSyncPushBlocked(type)) {
      results.push({ operationId: raw.operationId, status: 'FAILED', error: type === 'PART' ? 'PART_TENANCY_REQUIRED' : 'FINANCE_COMMAND_REQUIRED' });
      continue;
    }
    let entry: NormalizedEntry;
    try { entry = normalizeSyncEntry(raw, body.contractVersion); }
    catch (error) {
      results.push({ operationId: raw.operationId, status: 'FAILED', error: domainFailure(error) ?? 'SYNC_PAYLOAD_INVALID' }); continue;
    }
    const identity = {
      operationId: entry.operationId, actorUserId: principal.sub, organizationId: principal.organizationId,
      command: `SYNC_V${body.contractVersion}_${entry.entityType}_${entry.operationType}`,
      endpoint: '/api/v1/sync/push', requestHash: syncOperationHash(entry, body.contractVersion),
      // body.deviceId/userId never participate as authenticated identity.
    };
    const historical = await prisma.operationIdempotency.findUnique({ where: { operationId: entry.operationId } });
    if (historical && !historical.command) {
      results.push({ operationId: entry.operationId, status: 'CONFLICT', error: 'LEGACY_OPERATION_RECONCILIATION_REQUIRED' }); continue;
    }
    const reservation = await idempotency.reserveOrReplay(identity);
    if (reservation.kind === 'REPLAY') { results.push(reservation.responseBody as Prisma.InputJsonValue); continue; }
    if (reservation.kind !== 'ACQUIRED') {
      results.push({ operationId: entry.operationId, status: 'CONFLICT',
        error: reservation.kind === 'KEY_REUSE' ? 'IDEMPOTENCY_KEY_REUSE' : 'IDEMPOTENCY_OPERATION_IN_PROGRESS' }); continue;
    }
    try {
      const result = await syncTransaction(async tx => {
        await assertSyncPrincipal(tx, principal);
        await mutateSyncEntity(tx, principal, entry);
        const response = { operationId: entry.operationId, status: 'SYNCED' };
        await IdempotencyService.completeWithinTransaction(tx, { ...identity, leaseToken: reservation.leaseToken,
          responseStatus: 200, responseBody: response });
        return response;
      });
      results.push(result);
    } catch (error) {
      if (error instanceof IdempotencyStateConflictError) {
        results.push({ operationId: entry.operationId, status: 'CONFLICT', error: 'IDEMPOTENCY_STATE_CONFLICT' }); continue;
      }
      const reason = domainFailure(error);
      if (!reason) throw error; // Uncertain infrastructure failure retains the lease for safe reconciliation/retry.
      const response = { operationId: entry.operationId, status: 'FAILED', error: reason };
      try {
        await prisma.$transaction(tx => IdempotencyService.completeWithinTransaction(tx, {
          ...identity, leaseToken: reservation.leaseToken, responseStatus: 200, responseBody: response,
        }));
        results.push(response);
      } catch (completionError) {
        if (!(completionError instanceof IdempotencyStateConflictError)) throw completionError;
        results.push({ operationId: entry.operationId, status: 'CONFLICT', error: 'IDEMPOTENCY_STATE_CONFLICT' });
      }
    }
  }
  return reply.send({ results });
}

type Log = Prisma.SyncChangeLogGetPayload<{}>;
export function trustedChangeMetadata(change: Log) {
  const raw = change.data;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const { metadataMac, ...data } = raw;
  if (data.syncMetadataVersion !== 2 || !verifySyncMac('change-metadata', {
    id: change.id.toString(), entityType: change.entityType, entityId: change.entityId, operationType: change.operationType, data,
  }, metadataMac)) return null;
  const audience = data.audience as { organizationIds: string[]; customerIds: string[] };
  if (!audience || !Array.isArray(audience.organizationIds) || !Array.isArray(audience.customerIds)) return null;
  return { audience, parentId: typeof data.parentId === 'string' ? data.parentId : null, relationshipChange: data.relationshipChange === true };
}
function previouslyAuthorized(principal: SyncPrincipal, metadata: NonNullable<ReturnType<typeof trustedChangeMetadata>>) {
  return principal.role === 'CUSTOMER' ? metadata.audience.customerIds.includes(principal.customerId!) : metadata.audience.organizationIds.includes(principal.organizationId!);
}

export async function pullSyncHandler(request: FastifyRequest, reply: FastifyReply) {
  const query = pullSyncQuerySchema.parse(request.query);
  const principal = getAuthUser(request);
  const proof = query.contractVersion === 2 ? verifyBootstrapProof(bootstrapProofHeader(request), principal) : null;
  const cursor = query.cursor ?? '0';
  if (proof && (query.cursor === undefined || BigInt(cursor) < BigInt(proof.bootstrapCursor))) throw new ConflictError('SYNC_V2_BOOTSTRAP_REQUIRED');
  const response = await syncRead(async (tx, revision) => {
    await assertSyncPrincipal(tx, principal);
    if (BigInt(cursor) > BigInt(revision)) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
    const examined = await tx.syncChangeLog.findMany({ where: { id: { gt: BigInt(cursor), lte: BigInt(revision) } }, orderBy: { id: 'asc' }, take: query.limit });
    const changes: Prisma.InputJsonValue[] = [];
    for (const change of examined) {
      const type = change.entityType.toUpperCase();
      // PAYMENT is checked against the actual legacy row below; no union-of-IDs authorization.
      if (!isGenericSyncPullTypeAllowed({ entityType: type, role: principal.role, isAuthorizedLegacyPayment: true })) continue;
      const metadata = trustedChangeMetadata(change);
      let record;
      try { record = await readProjection(tx, principal, type, change.entityId, revision, query.contractVersion); }
      catch { throw new ConflictError('SYNC_V2_REFRESH_REQUIRED'); }
      if (record) {
        changes.push({ cursor: change.id.toString(), entityType: record.entityType, entityId: record.entityId,
          operationType: type === 'SERVICE_ORDER_ITEM' && query.contractVersion === 2 ? 'UPDATE' : change.operationType === 'DELETE' ? 'UPDATE' : change.operationType,
          data: record.data, createdAt: change.createdAt.toISOString() });
        continue;
      }
      if (type === 'PAYMENT') continue; // Never turn a Finance Core payment into a generic tombstone.
      if (metadata) {
        if (!previouslyAuthorized(principal, metadata)) continue;
        // Item events converge through the full parent aggregate, including deletions.
        if (type === 'SERVICE_ORDER_ITEM' && query.contractVersion === 2 && metadata.parentId) {
          let parent;
          try { parent = await readProjection(tx, principal, 'SERVICE_ORDER', metadata.parentId, revision, 2); }
          catch { throw new ConflictError('SYNC_V2_REFRESH_REQUIRED'); }
          if (parent) {
            changes.push({ cursor: change.id.toString(), entityType: 'SERVICE_ORDER', entityId: parent.entityId,
              operationType: 'UPDATE', data: parent.data, createdAt: change.createdAt.toISOString() }); continue;
          }
        }
        if (change.operationType !== 'DELETE') {
          const delegate = type === 'CUSTOMER' ? tx.customer : type === 'EQUIPMENT' ? tx.equipment : type === 'SERVICE_ORDER' ? tx.serviceOrder : tx.serviceOrderItem;
          const stillExists = await (delegate as any).findUnique({ where: { id: change.entityId }, select: { id: true } });
          if (!stillExists) {
            // Rehydration failure is not proof of deletion. Require a later,
            // server-authenticated tombstone from this same consistent cut.
            const deletion = await tx.syncChangeLog.findFirst({ where: {
              entityType: type, entityId: change.entityId, operationType: 'DELETE', id: { gt: change.id, lte: BigInt(revision) },
            }, orderBy: { id: 'desc' } });
            const deletionMetadata = deletion && trustedChangeMetadata(deletion);
            if (!deletionMetadata || !previouslyAuthorized(principal, deletionMetadata)) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
          }
        }
        changes.push({ cursor: change.id.toString(), entityType: type, entityId: change.entityId, operationType: 'DELETE',
          data: { id: change.entityId, deleted: true, parentId: metadata.parentId,
            ...(query.contractVersion === 2 ? { contractVersion: 2, projectionRevision: revision } : {}) },
          createdAt: change.createdAt.toISOString() });
      } else if (query.contractVersion === 2) {
        const delegate = type === 'CUSTOMER' ? tx.customer : type === 'EQUIPMENT' ? tx.equipment : type === 'SERVICE_ORDER' ? tx.serviceOrder : tx.serviceOrderItem;
        const stillExists = await (delegate as any).findUnique({ where: { id: change.entityId }, select: { id: true } });
        // A live unauthorized resource can be examined without disclosure.
        // Missing rows with unproven historical data require reconstruction.
        if (!stillExists) throw new ConflictError('SYNC_V2_REFRESH_REQUIRED');
      }
    }
    return { ...(query.contractVersion === 2 ? { contractVersion: 2 } : {}),
      nextCursor: examined.at(-1)?.id.toString() ?? cursor, changes };
  });
  return reply.send(response);
}

export async function bootstrapSyncHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = bootstrapSchema.parse(request.body);
  const principal = getAuthUser(request);
  if (body.continuationToken) {
    // Authentication is performed on every page, including replay/final proof.
    await syncRead(tx => assertSyncPrincipal(tx, principal));
    return reply.send(bootstrapStore.next(principal, body.continuationToken, body.limit));
  }
  const snapshot = await captureBootstrap(principal);
  return reply.send(bootstrapStore.begin(principal, snapshot.revision, snapshot.records, body.limit));
}
