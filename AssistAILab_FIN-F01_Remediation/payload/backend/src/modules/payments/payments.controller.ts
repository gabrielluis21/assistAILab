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
  authorizePaymentAdminLive,
  authorizePaymentMutationLive,
  authorizePaymentReadLive,
} from './payments.authorization.js';

import {
  createPaymentSchema,
  operationIdHeaderSchema,
  paymentIdParamsSchema,
  paymentListQuerySchema,
  updatePaymentStatusSchema,
} from './payments.schema.js';

import {
  PaymentsService,
  type PaymentCommandResult,
} from './payments.service.js';

const service =
  new PaymentsService();

function parseStrict<T>(
  schema: ZodType<T>,
  value: unknown
): T {
  const result =
    schema.safeParse(value);

  if (!result.success) {
    throw new AppError(
      'Validation Error',
      400
    );
  }

  return result.data;
}

export function parseOperationIdHeader(
  normalizedHeader:
    string | string[] | undefined,
  rawHeaders: string[]
): string {
  const rawMatches: string[] = [];

  for (
    let index = 0;
    index < rawHeaders.length;
    index += 2
  ) {
    if (
      rawHeaders[index]?.toLowerCase() ===
      'x-operation-id'
    ) {
      rawMatches.push(
        rawHeaders[index + 1] ?? ''
      );
    }
  }

  if (rawMatches.length !== 1) {
    throw new AppError(
      'X-Operation-Id must be provided exactly once',
      400
    );
  }

  if (
    Array.isArray(normalizedHeader) ||
    typeof normalizedHeader !== 'string' ||
    normalizedHeader.includes(',') ||
    rawMatches[0].includes(',')
  ) {
    throw new AppError(
      'X-Operation-Id is ambiguous',
      400
    );
  }

  const result =
    operationIdHeaderSchema.safeParse(
      rawMatches[0]
    );

  if (!result.success) {
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
  return parseOperationIdHeader(
    request.headers['x-operation-id'],
    request.raw.rawHeaders
  );
}

export function mapPaymentBoundaryError(
  error: unknown
):
  | {
    statusCode: 409;
    body: {
      error:
        'IDEMPOTENCY_STATE_CONFLICT';
    };
  }
  | null {
  if (
    error instanceof
    IdempotencyStateConflictError
  ) {
    return {
      statusCode: 409,
      body: {
        error:
          'IDEMPOTENCY_STATE_CONFLICT',
      },
    };
  }

  return null;
}

async function executePaymentCommand(
  reply: FastifyReply,
  command:
    () => Promise<PaymentCommandResult>
) {
  try {
    const result = await command();

    return reply
      .status(result.statusCode)
      .send(result.body);
  } catch (error) {
    const mapped =
      mapPaymentBoundaryError(error);

    if (mapped) {
      return reply
        .status(mapped.statusCode)
        .send(mapped.body);
    }

    throw error;
  }
}

export async function listPaymentsHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const user = getAuthUser(request);

  const organizationId =
    await authorizePaymentReadLive(user);

  const query = parseStrict(
    paymentListQuerySchema,
    request.query
  );

  const payments =
    await service.listAll(
      organizationId,
      query
    );

  return reply.send({ payments });
}

export async function getPaymentHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const user = getAuthUser(request);

  const organizationId =
    await authorizePaymentReadLive(user);

  const params = parseStrict(
    paymentIdParamsSchema,
    request.params
  );

  const payment =
    await service.findById(
      organizationId,
      params.id
    );

  return reply.send({ payment });
}

export async function createPaymentHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const user = getAuthUser(request);

  const organizationId =
    await authorizePaymentMutationLive(user);

  const operationId =
    requireOperationId(request);

  const body = parseStrict(
    createPaymentSchema,
    request.body
  );

  return executePaymentCommand(
    reply,
    () =>
      service.create(
        organizationId,
        user.sub,
        operationId,
        body
      )
  );
}

export async function updatePaymentStatusHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const user = getAuthUser(request);

  const organizationId =
    await authorizePaymentAdminLive(user);

  const operationId =
    requireOperationId(request);

  const params = parseStrict(
    paymentIdParamsSchema,
    request.params
  );

  const body = parseStrict(
    updatePaymentStatusSchema,
    request.body
  );

  return executePaymentCommand(
    reply,
    () =>
      service.updateStatus(
        organizationId,
        user.sub,
        operationId,
        params.id,
        body
      )
  );
}

export async function getRevenueSummaryHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const user = getAuthUser(request);

  const organizationId =
    await authorizePaymentAdminLive(user);

  const summary =
    await service.getRevenueSummary(
      organizationId
    );

  return reply.send(summary);
}
