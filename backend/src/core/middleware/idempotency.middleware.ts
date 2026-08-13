import crypto from 'node:crypto';
import { FastifyRequest, FastifyReply } from 'fastify';
import { prisma } from '../database/prisma.js';

export function computePayloadHash(payload: any): string {
  const normalized = payload ? JSON.stringify(payload) : '';
  return crypto.createHash('sha256').update(normalized).digest('hex');
}

export async function checkIdempotency(request: FastifyRequest, reply: FastifyReply): Promise<boolean> {
  const operationId = (request.headers['x-operation-id'] as string) || (request.body as Record<string, any>)?.operationId;

  if (!operationId) {
    return false;
  }

  const currentHash = computePayloadHash(request.body);
  const existing = await prisma.operationIdempotency.findUnique({
    where: { operationId },
  });

  if (existing) {
    if (existing.requestHash !== 'N/A' && existing.requestHash !== currentHash) {
      reply.status(409).send({
        error: 'IDEMPOTENCY_KEY_REUSE',
        message: 'Operation ID was previously used with a different request payload',
      });
      return true;
    }
    reply.status(existing.responseStatus).send(existing.responseBody);
    return true;
  }

  return false;
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
        responseStatus,
        responseBody: responseBody ?? {},
        userId,
        deviceId,
      },
    });
  } catch (error) {
    console.error('Failed to save operation idempotency:', error);
  }
}
