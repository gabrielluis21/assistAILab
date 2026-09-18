import type { FastifyReply, FastifyRequest } from 'fastify';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { authorizeFinanceCoreMutationLive } from './service_order_finance.authorization.js';
import { executeFinanceCommand, parseFinanceOperationIdHeader } from './service_order_finance.controller.js';
import { publishQuoteParamsSchema } from './service_order_finance.schema.js';
import { markReadySchema } from './mark_ready.schema.js';
import { markDelivered } from './mark_delivered.service.js';

export async function markDeliveredHandler(request: FastifyRequest, reply: FastifyReply) {
  const principal = getAuthUser(request);
  await authorizeFinanceCoreMutationLive(principal);
  const operationId = parseFinanceOperationIdHeader(request.headers['x-operation-id'], request.raw.rawHeaders);
  const { id } = publishQuoteParamsSchema.parse(request.params);
  const body = markReadySchema.parse(request.body ?? {});
  return executeFinanceCommand(reply, () => markDelivered(principal, operationId, id, body));
}
