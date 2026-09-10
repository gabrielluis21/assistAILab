import type {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import type {
  ZodType,
} from 'zod';

import {
  IdempotencyStateConflictError,
} from '../../core/idempotency/idempotency.service.js';

import {
  getAuthUser,
} from '../../core/middleware/auth.middleware.js';

import {
  AppError,
} from '../../core/utils/errors.js';

import {
  authorizeFinanceCoreMutationLive,
} from './service_order_finance.authorization.js';

import {
  financeOperationIdHeaderSchema,
  publishQuoteParamsSchema,
  publishQuoteSchema,
} from './service_order_finance.schema.js';

import {
  ServiceOrderFinanceService,
  type FinanceCommandResult,
} from './service_order_finance.service.js';

const service =
  new ServiceOrderFinanceService();

function parseStrict<T>(
  schema: ZodType<T>,
  value: unknown
): T {
  const result =
    schema.safeParse(
      value
    );

  if (
    !result.success
  ) {
    throw new AppError(
      'Validation Error',
      400
    );
  }

  return result.data;
}

export function parseFinanceOperationIdHeader(
  normalizedHeader:
    string |
    string[] |
    undefined,
  rawHeaders: string[]
): string {
  const rawMatches:
    string[] =
    [];

  for (
    let index = 0;
    index <
      rawHeaders.length;
    index += 2
  ) {
    if (
      rawHeaders[
        index
      ]
        ?.toLowerCase() ===
      'x-operation-id'
    ) {
      rawMatches.push(
        rawHeaders[
          index + 1
        ] ??
        ''
      );
    }
  }

  if (
    rawMatches.length !==
    1
  ) {
    throw new AppError(
      'X-Operation-Id must be provided exactly once',
      400
    );
  }

  if (
    Array.isArray(
      normalizedHeader
    ) ||
    typeof normalizedHeader !==
      'string' ||
    normalizedHeader
      .includes(',') ||
    rawMatches[0]
      .includes(',')
  ) {
    throw new AppError(
      'X-Operation-Id is ambiguous',
      400
    );
  }

  const result =
    financeOperationIdHeaderSchema
      .safeParse(
        rawMatches[0]
      );

  if (
    !result.success
  ) {
    throw new AppError(
      'X-Operation-Id must be a UUID',
      400
    );
  }

  return result.data;
}

function requireOperationId(
  request: FastifyRequest
): string {
  return parseFinanceOperationIdHeader(
    request.headers[
      'x-operation-id'
    ],
    request.raw
      .rawHeaders
  );
}

export async function executeFinanceCommand(
  reply: FastifyReply,
  command:
    () =>
      Promise<
        FinanceCommandResult
      >
) {
  try {
    const result =
      await command();

    return reply
      .status(
        result.statusCode
      )
      .send(
        result.body
      );
  } catch (error) {
    if (
      error instanceof
      IdempotencyStateConflictError
    ) {
      return reply
        .status(409)
        .send({
          error:
            'IDEMPOTENCY_STATE_CONFLICT',
        });
    }

    throw error;
  }
}

export async function publishInitialQuoteHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const user =
    getAuthUser(
      request
    );

  /**
   * Frozen order:
   * live authorization -> operation id -> H02 -> transaction.
   */
  const organizationId =
    await authorizeFinanceCoreMutationLive(
      user
    );

  const operationId =
    requireOperationId(
      request
    );

  const params =
    parseStrict(
      publishQuoteParamsSchema,
      request.params
    );

  const body =
    parseStrict(
      publishQuoteSchema,
      request.body ??
        {}
    );

  return executeFinanceCommand(
    reply,
    () =>
      service
        .publishInitialQuote(
          organizationId,
          user.sub,
          operationId,
          params.id,
          body
        )
  );
}
