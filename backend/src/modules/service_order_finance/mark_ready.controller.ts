import type {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  getAuthUser,
} from '../../core/middleware/auth.middleware.js';

import {
  authorizeFinanceCoreMutationLive,
} from './service_order_finance.authorization.js';

import {
  executeFinanceCommand,
  parseFinanceOperationIdHeader,
} from './service_order_finance.controller.js';

import {
  markReadySchema,
} from './mark_ready.schema.js';

import {
  publishQuoteParamsSchema,
} from './service_order_finance.schema.js';

import {
  markReadyFinanceService,
} from './mark_ready.service.js';

export async function markReadyFinanceHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  const organizationId =
    await authorizeFinanceCoreMutationLive(
      authUser
    );

  const operationId =
    parseFinanceOperationIdHeader(
      request.headers[
        'x-operation-id'
      ],
      request.raw
        .rawHeaders
    );

  const params =
    publishQuoteParamsSchema
      .parse(
        request.params
      );

  const body =
    markReadySchema
      .parse(
        request.body ??
        {}
      );

  return executeFinanceCommand(
    reply,
    () =>
      markReadyFinanceService
        .markReadyAndIssueReceivable(
          organizationId,
          authUser.sub,
          operationId,
          params.id,
          body
        )
  );
}
