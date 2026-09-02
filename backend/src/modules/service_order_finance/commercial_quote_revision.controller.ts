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
  publishCommercialQuoteRevisionSchema,
} from './commercial_quote_revision.schema.js';

import {
  commercialQuoteRevisionService,
} from './commercial_quote_revision.service.js';

export async function publishCommercialQuoteRevisionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  /**
   * Frozen order:
   * live authorization -> exact operation ID -> H02 -> SO lock.
   */
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

  const {
    id,
  } =
    request.params as {
      id:
        string;
    };

  const body =
    publishCommercialQuoteRevisionSchema
      .parse(
        request.body
      );

  return executeFinanceCommand(
    reply,
    () =>
      commercialQuoteRevisionService
        .publishCommercialRevision(
          organizationId,
          authUser.sub,
          operationId,
          id,
          body
        )
  );
}
