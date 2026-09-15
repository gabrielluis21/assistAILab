import type { FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';
import { syncRead } from '../../core/database/sync_transaction.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ConflictError, NotFoundError } from '../../core/utils/errors.js';
import { assertSyncPrincipal, readProjection } from '../sync/sync.projection.js';

/** Canonical refresh after a dedicated quote command. The command's immutable
 * idempotent response is preserved; this read supplies current aggregate state. */
export async function getServiceOrderProjectionHandler(request: FastifyRequest, reply: FastifyReply) {
  const { id } = z.object({ id: z.string().uuid() }).parse(request.params);
  const principal = getAuthUser(request);
  const record = await syncRead(async (tx, revision) => {
    await assertSyncPrincipal(tx, principal);
    try { return await readProjection(tx, principal, 'SERVICE_ORDER', id, revision, 2); }
    catch { throw new ConflictError('SYNC_V2_REFRESH_REQUIRED'); }
  });
  if (!record) throw new NotFoundError('Service Order not found');
  return reply.send(record.data);
}
