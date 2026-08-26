import {
  describe,
  test,
  after,
} from 'node:test';

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import {
  IdempotencyStatus,
} from '@prisma/client';

import {
  computeCanonicalHash,
} from './canonical_json.js';

import {
  IdempotencyService,
  IdempotencyStateConflictError,
} from './idempotency.service.js';

import {
  prisma,
} from '../database/prisma.js';

describe(
  'SEC-F01-H02 Idempotency lease ownership',
  {
    concurrency: false,
  },
  () => {
    const operationIds: string[] = [];
    const markerIds: string[] = [];

    after(async () => {
      if (markerIds.length > 0) {
        await prisma.syncChangeLog.deleteMany({
          where: {
            cursor: {
              in: markerIds,
            },
          },
        });
      }

      if (operationIds.length > 0) {
        await prisma.operationIdempotency.deleteMany({
          where: {
            operationId: {
              in: operationIds,
            },
          },
        });
      }
    });

    function identity() {
      const operationId = randomUUID();
      operationIds.push(operationId);

      return {
        operationId,
        actorUserId: randomUUID(),
        organizationId: randomUUID(),
        command: 'SEC_F01_H02_TEST',
        endpoint: '/sec-f01-h02/test',
        requestHash: computeCanonicalHash({
          purpose: 'lease-ownership',
        }),
      };
    }

    test(
      'reservation creates an internal lease token and completion clears it',
      async () => {
        const input = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const acquired = await service.reserveOrReplay(input);

        assert.equal(acquired.kind, 'ACQUIRED');
        if (acquired.kind !== 'ACQUIRED') assert.fail('Expected ACQUIRED');

        assert.match(
          acquired.leaseToken,
          /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        );

        const processing =
          await prisma.operationIdempotency.findUniqueOrThrow({
            where: {
              operationId: input.operationId,
            },
          });

        assert.equal(processing.leaseToken, acquired.leaseToken);

        await prisma.$transaction(async (tx) => {
          await IdempotencyService.completeWithinTransaction(tx, {
            ...input,
            leaseToken: acquired.leaseToken,
            responseStatus: 200,
            responseBody: {
              ok: true,
            },
          });
        });

        const completed =
          await prisma.operationIdempotency.findUniqueOrThrow({
            where: {
              operationId: input.operationId,
            },
          });

        assert.equal(completed.status, IdempotencyStatus.COMPLETED);
        assert.equal(completed.leaseToken, null);
      }
    );

    test(
      'takeover rotates token and concurrent takeover has one winner',
      async () => {
        const input = identity();
        const now = new Date();
        const originalToken = randomUUID();

        await prisma.operationIdempotency.create({
          data: {
            operationId: input.operationId,
            userId: input.actorUserId,
            organizationId: input.organizationId,
            command: input.command,
            endpoint: input.endpoint,
            requestHash: input.requestHash,
            status: IdempotencyStatus.PROCESSING,
            processingExpiresAt: new Date(now.getTime() - 5_000),
            leaseToken: originalToken,
          },
        });

        const service = new IdempotencyService(prisma, 60_000);

        const [a, b] = await Promise.all([
          service.takeoverExpired({
            ...input,
            now,
          }),
          service.takeoverExpired({
            ...input,
            now,
          }),
        ]);

        const winners = [a, b].filter(
          (
            value
          ): value is {
            processingExpiresAt: Date;
            leaseToken: string;
          } => value !== null
        );

        assert.equal(winners.length, 1);
        assert.notEqual(winners[0].leaseToken, originalToken);

        const stored =
          await prisma.operationIdempotency.findUniqueOrThrow({
            where: {
              operationId: input.operationId,
            },
          });

        assert.equal(stored.leaseToken, winners[0].leaseToken);
      }
    );

    test(
      'stale worker rolls back its transaction and current owner completes',
      async () => {
        const input = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const first = await service.reserveOrReplay({
          ...input,
          leaseMs: 1,
          now: new Date(Date.now() - 10_000),
        });

        assert.equal(first.kind, 'ACQUIRED');
        if (first.kind !== 'ACQUIRED') assert.fail('Expected ACQUIRED');

        const second = await service.takeoverExpired({
          ...input,
          now: new Date(),
          leaseMs: 60_000,
        });

        assert.ok(second);
        assert.notEqual(first.leaseToken, second.leaseToken);

        const staleCursor = randomUUID();
        markerIds.push(staleCursor);

        await assert.rejects(
          prisma.$transaction(async (tx) => {
            await tx.syncChangeLog.create({
              data: {
                cursor: staleCursor,
                entityType: 'SEC_F01_H02_TEST',
                entityId: randomUUID(),
                operationType: 'UPDATE',
                data: {
                  worker: 'stale',
                },
              },
            });

            await IdempotencyService.completeWithinTransaction(tx, {
              ...input,
              leaseToken: first.leaseToken,
              responseStatus: 200,
              responseBody: {
                worker: 'stale',
              },
            });
          }),
          IdempotencyStateConflictError
        );

        assert.equal(
          await prisma.syncChangeLog.findUnique({
            where: {
              cursor: staleCursor,
            },
          }),
          null
        );

        const currentCursor = randomUUID();
        markerIds.push(currentCursor);

        await prisma.$transaction(async (tx) => {
          await tx.syncChangeLog.create({
            data: {
              cursor: currentCursor,
              entityType: 'SEC_F01_H02_TEST',
              entityId: randomUUID(),
              operationType: 'UPDATE',
              data: {
                worker: 'current',
              },
            },
          });

          await IdempotencyService.completeWithinTransaction(tx, {
            ...input,
            leaseToken: second.leaseToken,
            responseStatus: 200,
            responseBody: {
              worker: 'current',
            },
          });
        });

        assert.ok(
          await prisma.syncChangeLog.findUnique({
            where: {
              cursor: currentCursor,
            },
          })
        );

        const completed =
          await prisma.operationIdempotency.findUniqueOrThrow({
            where: {
              operationId: input.operationId,
            },
          });

        assert.equal(completed.status, IdempotencyStatus.COMPLETED);
        assert.equal(completed.leaseToken, null);
        assert.deepEqual(completed.responseBody, {
          worker: 'current',
        });
      }
    );

    test(
      'lease token is not part of canonical hash',
      () => {
        const envelope = {
          command: 'SEC_F01_H02_TEST',
          endpoint: '/sec-f01-h02/test',
          actorUserId: randomUUID(),
          organizationId: randomUUID(),
          payload: {
            amountMinor: 1050,
          },
        };

        const firstHash = computeCanonicalHash(envelope);
        const leaseA = randomUUID();
        const leaseB = randomUUID();

        assert.notEqual(leaseA, leaseB);
        assert.equal(firstHash, computeCanonicalHash(envelope));
      }
    );
  }
);
