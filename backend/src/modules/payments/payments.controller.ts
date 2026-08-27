import type {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import type {
  ZodType,
} from 'zod';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  AppError,
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  createPaymentSchema,
  operationIdHeaderSchema,
  paymentIdParamsSchema,
  paymentListQuerySchema,
  updatePaymentStatusSchema,
} from './payments.schema.js';

import {
  PaymentsService,
} from './payments.service.js';

const service =
  new PaymentsService();

function parseStrict<T>(
  schema:
    ZodType<T>,
  value:
    unknown
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

function requireStaff(
  request:
    FastifyRequest
) {
  const user =
    getAuthUser(
      request
    );

  if (
    ![
      'ADMIN',
      'TECHNICIAN',
    ].includes(
      user.role
    )
  ) {
    throw new ForbiddenError(
      'Payments are available only to organization staff'
    );
  }

  return {
    user,
    organizationId:
      requireOrganizationId(
        user
      ),
  };
}

function requireAdmin(
  request:
    FastifyRequest
) {
  const context =
    requireStaff(
      request
    );

  if (
    context.user.role !==
    'ADMIN'
  ) {
    throw new ForbiddenError(
      'ADMIN role is required'
    );
  }

  return context;
}

function requireOperationId(
  request:
    FastifyRequest
): string {
  const raw =
    request.headers[
      'x-operation-id'
    ];

  const value =
    Array.isArray(raw)
      ? raw[0]
      : raw;

  const result =
    operationIdHeaderSchema
      .safeParse(
        value
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

export async function listPaymentsHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    organizationId,
  } =
    requireStaff(
      request
    );

  const query =
    parseStrict(
      paymentListQuerySchema,
      request.query
    );

  const payments =
    await service.listAll(
      organizationId,
      query
    );

  return reply.send({
    payments,
  });
}

export async function getPaymentHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    organizationId,
  } =
    requireStaff(
      request
    );

  const params =
    parseStrict(
      paymentIdParamsSchema,
      request.params
    );

  const payment =
    await service.findById(
      organizationId,
      params.id
    );

  return reply.send({
    payment,
  });
}

export async function createPaymentHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    user,
    organizationId,
  } =
    requireStaff(
      request
    );

  const operationId =
    requireOperationId(
      request
    );

  const body =
    parseStrict(
      createPaymentSchema,
      request.body
    );

  const result =
    await service.create(
      organizationId,
      user.sub,
      operationId,
      body
    );

  return reply
    .status(
      result.statusCode
    )
    .send(
      result.body
    );
}

export async function updatePaymentStatusHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    user,
    organizationId,
  } =
    requireAdmin(
      request
    );

  const operationId =
    requireOperationId(
      request
    );

  const params =
    parseStrict(
      paymentIdParamsSchema,
      request.params
    );

  const body =
    parseStrict(
      updatePaymentStatusSchema,
      request.body
    );

  const result =
    await service
      .updateStatus(
        organizationId,
        user.sub,
        operationId,
        params.id,
        body
      );

  return reply
    .status(
      result.statusCode
    )
    .send(
      result.body
    );
}

export async function getRevenueSummaryHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    organizationId,
  } =
    requireAdmin(
      request
    );

  const summary =
    await service
      .getRevenueSummary(
        organizationId
      );

  return reply.send(
    summary
  );
}
