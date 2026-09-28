import type { FastifyReply, FastifyRequest } from 'fastify';
import { z } from 'zod';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';
import {
  AppError,
  ForbiddenError,
} from '../../core/utils/errors.js';
import {
  authorizeEquipmentAcquisitionSchema,
  authorizeInPersonSchema,
  createDirectOfferSchema,
  createEquipmentAcquisitionSchema,
  emptyAcquisitionMutationSchema,
} from './equipment_acquisitions.schema.js';
import {
  EquipmentAcquisitionService,
  type AcquisitionCommandResult,
} from './equipment_acquisitions.service.js';

const service = new EquipmentAcquisitionService();
const operationIdSchema = z.string().uuid();
const idSchema = z.string().uuid();

function requireCustomerId(request: FastifyRequest): string {
  const authUser = getAuthUser(request);
  if (authUser.role !== 'CUSTOMER' || !authUser.customerId) {
    throw new ForbiddenError('Customer identity is required');
  }
  return authUser.customerId;
}

export function parseAcquisitionOperationIdHeader(
  normalizedHeader: string | string[] | undefined,
  rawHeaders: string[]
): string {
  const rawMatches: string[] = [];
  for (let index = 0; index < rawHeaders.length; index += 2) {
    if (rawHeaders[index]?.toLowerCase() === 'x-operation-id') {
      rawMatches.push(rawHeaders[index + 1] ?? '');
    }
  }
  if (rawMatches.length !== 1) {
    throw new AppError('X-Operation-Id must be provided exactly once', 400);
  }
  if (
    Array.isArray(normalizedHeader) ||
    typeof normalizedHeader !== 'string' ||
    normalizedHeader.includes(',') ||
    rawMatches[0].includes(',')
  ) {
    throw new AppError('X-Operation-Id is ambiguous', 400);
  }
  const parsed = operationIdSchema.safeParse(rawMatches[0]);
  if (!parsed.success) throw new AppError('X-Operation-Id must be a UUID', 400);
  return parsed.data;
}

function operationId(request: FastifyRequest): string {
  return parseAcquisitionOperationIdHeader(
    request.headers['x-operation-id'],
    request.raw.rawHeaders
  );
}

function acquisitionId(request: FastifyRequest): string {
  const parsed = idSchema.safeParse((request.params as { id?: unknown }).id);
  if (!parsed.success) throw new AppError('Equipment acquisition id must be a UUID', 400);
  return parsed.data;
}

function sendCommand(reply: FastifyReply, result: AcquisitionCommandResult) {
  return reply.status(result.statusCode).send(result.body);
}

export async function listEquipmentAcquisitionsHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser = getAuthUser(request);
  if (authUser.role === 'CUSTOMER') {
    const acquisitions = await service.listForCustomer(requireCustomerId(request));
    return reply.send({ acquisitions });
  }
  const acquisitions = await service.listForOrganization(requireOrganizationId(authUser));
  return reply.send({ acquisitions });
}

export async function getEquipmentAcquisitionHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const id = acquisitionId(request);
  const authUser = getAuthUser(request);
  if (authUser.role === 'CUSTOMER') {
    const acquisition = await service.findForCustomer(id, requireCustomerId(request));
    return reply.send({ acquisition });
  }
  const acquisition = await service.findForOrganization(id, requireOrganizationId(authUser));
  return reply.send({ acquisition });
}

export async function createEquipmentAcquisitionHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const result = await service.createProposal(
    getAuthUser(request),
    operationId(request),
    createEquipmentAcquisitionSchema.parse(request.body)
  );
  return sendCommand(reply, result);
}

export async function createDirectOfferHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const result = await service.createDirectOffer(
    getAuthUser(request),
    operationId(request),
    createDirectOfferSchema.parse(request.body)
  );
  return sendCommand(reply, result);
}

export async function authorizeEquipmentAcquisitionHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  requireCustomerId(request);
  const result = await service.authorize(
    getAuthUser(request),
    operationId(request),
    acquisitionId(request),
    authorizeEquipmentAcquisitionSchema.parse(request.body)
  );
  return sendCommand(reply, result);
}

export async function authorizeInPersonHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const result = await service.authorizeInPerson(
    getAuthUser(request),
    operationId(request),
    acquisitionId(request),
    authorizeInPersonSchema.parse(request.body)
  );
  return sendCommand(reply, result);
}

export async function rejectEquipmentAcquisitionHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  requireCustomerId(request);
  emptyAcquisitionMutationSchema.parse(request.body ?? {});
  const result = await service.reject(
    getAuthUser(request),
    operationId(request),
    acquisitionId(request)
  );
  return sendCommand(reply, result);
}

export async function completeEquipmentAcquisitionHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  emptyAcquisitionMutationSchema.parse(request.body ?? {});
  const result = await service.complete(
    getAuthUser(request),
    operationId(request),
    acquisitionId(request)
  );
  return sendCommand(reply, result);
}
