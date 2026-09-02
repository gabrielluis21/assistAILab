import type {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  getAuthUser,
} from '../../core/middleware/auth.middleware.js';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  authorizeFinanceCoreMutationLive,
} from '../service_order_finance/service_order_finance.authorization.js';

import {
  executeFinanceCommand,
  parseFinanceOperationIdHeader,
} from '../service_order_finance/service_order_finance.controller.js';

import {
  cancelReceivableSchema,
  receivableIdParamsSchema,
  rescheduleReceivableSchema,
} from './receivables.schema.js';

import {
  receivablesFinanceService,
} from './receivables.service.js';

async function requireLiveAdmin(
  request:
    FastifyRequest
) {
  const user =
    getAuthUser(
      request
    );

  const organizationId =
    await authorizeFinanceCoreMutationLive(
      user
    );

  if (
    user.role !==
    'ADMIN'
  ) {
    throw new ForbiddenError(
      'ADMIN Finance Core authorization is required'
    );
  }

  return {
    user,
    organizationId,
  };
}

function operationId(
  request:
    FastifyRequest
) {
  return parseFinanceOperationIdHeader(
    request.headers[
      'x-operation-id'
    ],
    request.raw
      .rawHeaders
  );
}

export async function rescheduleReceivableHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    user,
    organizationId,
  } =
    await requireLiveAdmin(
      request
    );

  const commandOperationId =
    operationId(
      request
    );

  const params =
    receivableIdParamsSchema
      .parse(
        request.params
      );

  const body =
    rescheduleReceivableSchema
      .parse(
        request.body
      );

  return executeFinanceCommand(
    reply,
    () =>
      receivablesFinanceService
        .reschedule(
          organizationId,
          user.sub,
          commandOperationId,
          params.id,
          body
        )
  );
}

export async function cancelReceivableHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    user,
    organizationId,
  } =
    await requireLiveAdmin(
      request
    );

  const commandOperationId =
    operationId(
      request
    );

  const params =
    receivableIdParamsSchema
      .parse(
        request.params
      );

  const body =
    cancelReceivableSchema
      .parse(
        request.body
      );

  return executeFinanceCommand(
    reply,
    () =>
      receivablesFinanceService
        .cancel(
          organizationId,
          user.sub,
          commandOperationId,
          params.id,
          body
        )
  );
}
