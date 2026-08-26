import {
  IdempotencyStatus,
  Prisma,
  type PrismaClient,
} from '@prisma/client';

import type {
  CompleteIdempotencyInput,
  IdempotencyIdentity,
  ReserveIdempotencyInput,
  ReserveIdempotencyResult,
} from './idempotency.types.js';

const DEFAULT_LEASE_MS = 5 * 60 * 1000;

type PrismaRootClient = Pick<PrismaClient, 'operationIdempotency'>;

function sameNullableString(
  left: string | null,
  right: string | null | undefined
): boolean {
  return left === (right ?? null);
}

function sameIdentity(
  existing: {
    operationId: string;
    userId: string | null;
    organizationId: string | null;
    command: string | null;
    endpoint: string;
    requestHash: string;
  },
  input: IdempotencyIdentity
): boolean {
  return (
    existing.operationId === input.operationId &&
    sameNullableString(existing.userId, input.actorUserId) &&
    sameNullableString(existing.organizationId, input.organizationId) &&
    sameNullableString(existing.command, input.command) &&
    existing.endpoint === input.endpoint &&
    existing.requestHash === input.requestHash
  );
}

export class IdempotencyStateConflictError extends Error {
  constructor(message = 'Idempotency state changed concurrently') {
    super(message);
    this.name = 'IdempotencyStateConflictError';
  }
}

export class IdempotencyService {
  constructor(
    private readonly db: PrismaRootClient | Prisma.TransactionClient,
    private readonly defaultLeaseMs = DEFAULT_LEASE_MS
  ) {}

  private leaseExpiry(now: Date, leaseMs?: number): Date {
    const effectiveLease = leaseMs ?? this.defaultLeaseMs;

    if (!Number.isSafeInteger(effectiveLease) || effectiveLease <= 0) {
      throw new Error('leaseMs must be a positive safe integer');
    }

    return new Date(now.getTime() + effectiveLease);
  }

  async reserveOrReplay(
    input: ReserveIdempotencyInput
  ): Promise<ReserveIdempotencyResult> {
    const now = input.now ?? new Date();
    const processingExpiresAt = this.leaseExpiry(now, input.leaseMs);

    try {
      await this.db.operationIdempotency.create({
        data: {
          operationId: input.operationId,
          userId: input.actorUserId,
          organizationId: input.organizationId,
          deviceId: input.deviceId ?? null,
          command: input.command,
          endpoint: input.endpoint,
          requestHash: input.requestHash,
          status: IdempotencyStatus.PROCESSING,
          processingExpiresAt,
        },
      });

      return {
        kind: 'ACQUIRED',
        processingExpiresAt,
      };
    } catch (error: any) {
      if (error?.code !== 'P2002') {
        throw error;
      }
    }

    const existing = await this.db.operationIdempotency.findUnique({
      where: {
        operationId: input.operationId,
      },
    });

    if (!existing) {
      throw new IdempotencyStateConflictError(
        'Idempotency reservation disappeared after unique conflict'
      );
    }

    if (!sameIdentity(existing, input)) {
      return {
        kind: 'KEY_REUSE',
      };
    }

    if (existing.status === IdempotencyStatus.COMPLETED) {
      if (
        existing.responseStatus === null ||
        existing.responseBody === null ||
        existing.completedAt === null
      ) {
        throw new IdempotencyStateConflictError(
          'COMPLETED idempotency record is missing canonical response data'
        );
      }

      return {
        kind: 'REPLAY',
        responseStatus: existing.responseStatus,
        responseBody: existing.responseBody,
      };
    }

    if (
      existing.processingExpiresAt &&
      existing.processingExpiresAt.getTime() > now.getTime()
    ) {
      return {
        kind: 'IN_PROGRESS',
        processingExpiresAt: existing.processingExpiresAt,
      };
    }

    const takeover = await this.takeoverExpired({
      ...input,
      now,
    });

    if (takeover) {
      return {
        kind: 'ACQUIRED',
        processingExpiresAt: takeover,
      };
    }

    const reloaded = await this.db.operationIdempotency.findUnique({
      where: {
        operationId: input.operationId,
      },
    });

    if (!reloaded) {
      throw new IdempotencyStateConflictError(
        'Idempotency record disappeared during lease takeover'
      );
    }

    if (!sameIdentity(reloaded, input)) {
      return {
        kind: 'KEY_REUSE',
      };
    }

    if (reloaded.status === IdempotencyStatus.COMPLETED) {
      if (
        reloaded.responseStatus === null ||
        reloaded.responseBody === null ||
        reloaded.completedAt === null
      ) {
        throw new IdempotencyStateConflictError(
          'COMPLETED idempotency record is missing canonical response data'
        );
      }

      return {
        kind: 'REPLAY',
        responseStatus: reloaded.responseStatus,
        responseBody: reloaded.responseBody,
      };
    }

    return {
      kind: 'IN_PROGRESS',
      processingExpiresAt: reloaded.processingExpiresAt,
    };
  }

  async takeoverExpired(
    input: ReserveIdempotencyInput
  ): Promise<Date | null> {
    const now = input.now ?? new Date();
    const newLease = this.leaseExpiry(now, input.leaseMs);

    const takeover = await this.db.operationIdempotency.updateMany({
      where: {
        operationId: input.operationId,
        status: IdempotencyStatus.PROCESSING,
        processingExpiresAt: {
          lt: now,
        },
        userId: input.actorUserId,
        organizationId: input.organizationId,
        command: input.command,
        endpoint: input.endpoint,
        requestHash: input.requestHash,
      },
      data: {
        processingExpiresAt: newLease,
      },
    });

    return takeover.count === 1 ? newLease : null;
  }

  static async completeWithinTransaction(
    tx: Prisma.TransactionClient,
    input: CompleteIdempotencyInput
  ): Promise<void> {
    const completedAt = input.completedAt ?? new Date();

    const result = await tx.operationIdempotency.updateMany({
      where: {
        operationId: input.operationId,
        status: IdempotencyStatus.PROCESSING,
        userId: input.actorUserId,
        organizationId: input.organizationId,
        command: input.command,
        endpoint: input.endpoint,
        requestHash: input.requestHash,
      },
      data: {
        status: IdempotencyStatus.COMPLETED,
        responseStatus: input.responseStatus,
        responseBody: input.responseBody,
        completedAt,
        processingExpiresAt: null,
      },
    });

    if (result.count !== 1) {
      throw new IdempotencyStateConflictError(
        'Could not transition idempotency record from PROCESSING to COMPLETED'
      );
    }
  }
}
