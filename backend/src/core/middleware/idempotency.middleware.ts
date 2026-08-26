import { FastifyRequest, FastifyReply } from 'fastify';
import { IdempotencyStatus } from '@prisma/client';
import { prisma } from '../database/prisma.js';
import { computeCanonicalHash } from '../idempotency/canonical_json.js';

/**
 * Legacy compatibility facade.
 *
 * New Finance Commands MUST use IdempotencyService v2 directly.
 */
export function computePayloadHash(payload: any): string {
  return computeCanonicalHash(payload === undefined ? null : payload);
}

export async function checkIdempotency(
  request: FastifyRequest,
  reply: FastifyReply
): Promise<boolean> {
  const operationId =
    (request.headers['x-operation-id'] as string) ||
    (request.body as Record<string, any>)?.operationId;

  if (!operationId) {
    return false;
  }

  const currentHash = computePayloadHash(request.body);

  const existing = await prisma.operationIdempotency.findUnique({
    where: { operationId },
  });

  if (!existing) {
    return false;
  }

  if (
    existing.requestHash !== 'N/A' &&
    existing.requestHash !== currentHash
  ) {
    reply.status(409).send({
      error: 'IDEMPOTENCY_KEY_REUSE',
      message:
        'Operation ID was previously used with a different request payload',
    });
    return true;
  }

  if (
    existing.status === IdempotencyStatus.PROCESSING ||
    existing.responseStatus === null ||
    existing.responseBody === null
  ) {
    reply.status(409).send({
      error: 'IDEMPOTENCY_IN_PROGRESS',
    });
    return true;
  }

  reply
    .status(existing.responseStatus)
    .send(existing.responseBody);

  return true;
}

export async function saveIdempotency(
  operationId: string,
  endpoint: string,
  responseStatus: number,
  responseBody: any,
  requestPayload?: any,
  userId?: string,
  deviceId?: string
) {
  try {
    const requestHash = computePayloadHash(requestPayload);

    await prisma.operationIdempotency.create({
      data: {
        operationId,
        endpoint,
        requestHash,
        status: IdempotencyStatus.COMPLETED,
        responseStatus,
        responseBody: responseBody ?? {},
        completedAt: new Date(),
        userId,
        deviceId,
      },
    });
  } catch (error) {
    console.error('Failed to save operation idempotency:', error);
  }
}
