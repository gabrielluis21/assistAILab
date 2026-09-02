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
  publishQuoteParamsSchema,
} from './service_order_finance.schema.js';

import {
  resumeApprovedScopeSchema,
} from './resume_approved_scope.schema.js';

import {
  resumeApprovedScopeService,
} from './resume_approved_scope.service.js';

export async function resumePriorApprovedScopeHandler(
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
      request.raw.rawHeaders
    );

  const params =
    publishQuoteParamsSchema.parse(
      request.params
    );

  const body =
    resumeApprovedScopeSchema.parse(
      request.body
    );

  return executeFinanceCommand(
    reply,
    () =>
      resumeApprovedScopeService
        .resumePriorApprovedScope(
          organizationId,
          authUser.sub,
          operationId,
          params.id,
          body
        )
  );
}
