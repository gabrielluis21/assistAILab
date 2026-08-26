import type { Prisma } from '@prisma/client';

export type IdempotencyIdentity = {
  operationId: string;
  actorUserId: string;
  organizationId: string;
  deviceId?: string | null;
  command: string;
  endpoint: string;
  requestHash: string;
};

export type ReserveIdempotencyInput = IdempotencyIdentity & {
  leaseMs?: number;
  now?: Date;
};

export type CompleteIdempotencyInput = IdempotencyIdentity & {
  responseStatus: number;
  responseBody: Prisma.InputJsonValue;
  completedAt?: Date;
};

export type ReserveIdempotencyResult =
  | {
      kind: 'ACQUIRED';
      processingExpiresAt: Date;
    }
  | {
      kind: 'REPLAY';
      responseStatus: number;
      responseBody: Prisma.JsonValue;
    }
  | {
      kind: 'IN_PROGRESS';
      processingExpiresAt: Date | null;
    }
  | {
      kind: 'KEY_REUSE';
    };
