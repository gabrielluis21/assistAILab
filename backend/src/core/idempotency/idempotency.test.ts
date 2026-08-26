import {
  describe,
  test,
  before,
  after,
} from 'node:test';

import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';

import {
  IdempotencyStatus,
} from '@prisma/client';

import {
  canonicalJsonStringify,
  computeCanonicalHash,
  UnsupportedCanonicalValueError,
} from './canonical_json.js';

import {
  IdempotencyService,
} from './idempotency.service.js';

import {
  prisma,
} from '../database/prisma.js';

describe(
  'SEC-F01 Idempotency v2',
  {
    concurrency: false,
  },
  () => {
    const createdOperationIds: string[] = [];

    after(async () => {
      if (createdOperationIds.length > 0) {
        await prisma.operationIdempotency.deleteMany({
          where: {
            operationId: {
              in: createdOperationIds,
            },
          },
        });
      }
    });

    function identity(
      overrides: Partial<{
        operationId: string;
        actorUserId: string;
        organizationId: string;
        command: string;
        endpoint: string;
        requestHash: string;
      }> = {}
    ) {
      const operationId = overrides.operationId ?? randomUUID();
      if (!createdOperationIds.includes(operationId)) {
        createdOperationIds.push(operationId);
      }

      return {
        operationId,
        actorUserId: overrides.actorUserId ?? randomUUID(),
        organizationId: overrides.organizationId ?? randomUUID(),
        command: overrides.command ?? 'SEC_F01_TEST_COMMAND',
        endpoint: overrides.endpoint ?? '/sec-f01/test',
        requestHash:
          overrides.requestHash ??
          computeCanonicalHash({
            amountMinor: 10000,
            method: 'PIX',
          }),
      };
    }

    test(
      'canonical JSON ignores object key order recursively and preserves array order',
      () => {
        const a = {
          b: 2,
          nested: {
            z: true,
            a: 'x',
          },
          arr: [1, 2],
        };

        const b = {
          arr: [1, 2],
          nested: {
            a: 'x',
            z: true,
          },
          b: 2,
        };

        const c = {
          arr: [2, 1],
          nested: {
            a: 'x',
            z: true,
          },
          b: 2,
        };

        assert.equal(
          canonicalJsonStringify(a),
          canonicalJsonStringify(b)
        );

        assert.equal(
          computeCanonicalHash(a),
          computeCanonicalHash(b)
        );

        assert.notEqual(
          computeCanonicalHash(a),
          computeCanonicalHash(c)
        );
      }
    );

    test(
      'canonical JSON normalizes negative zero to zero',
      () => {
        assert.equal(
          canonicalJsonStringify({ value: -0 }),
          canonicalJsonStringify({ value: 0 })
        );

        assert.equal(
          computeCanonicalHash({ value: -0 }),
          computeCanonicalHash({ value: 0 })
        );
      }
    );

    test(
      'canonical JSON rejects non-JSON domain values',
      () => {
        class ExampleClass {
          value = 1;
        }

        const invalidValues: unknown[] = [
          undefined,
          Number.NaN,
          Number.POSITIVE_INFINITY,
          Number.NEGATIVE_INFINITY,
          BigInt(1),
          new Date(),
          new Map(),
          new Set(),
          () => undefined,
          Symbol('x'),
          new ExampleClass(),
          /x/,
        ];

        for (const value of invalidValues) {
          assert.throws(
            () => canonicalJsonStringify(value),
            UnsupportedCanonicalValueError
          );
        }

        assert.throws(
          () =>
            canonicalJsonStringify({
              nested: {
                invalid: undefined,
              },
            }),
          UnsupportedCanonicalValueError
        );
      }
    );

    test(
      'same operation and same canonical request replays stored response after COMPLETED',
      async () => {
        const input = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const reserved = await service.reserveOrReplay(input);
        assert.equal(reserved.kind, 'ACQUIRED');
        if (reserved.kind !== 'ACQUIRED') {
          assert.fail('Expected ACQUIRED');
        }

        await prisma.$transaction(async (tx) => {
          await IdempotencyService.completeWithinTransaction(tx, {
            ...input,
            leaseToken: reserved.leaseToken,
            responseStatus: 201,
            responseBody: {
              ok: true,
              id: 'canonical-result',
            },
          });
        });

        const replay = await service.reserveOrReplay(input);

        assert.equal(replay.kind, 'REPLAY');

        if (replay.kind === 'REPLAY') {
          assert.equal(replay.responseStatus, 201);
          assert.deepEqual(replay.responseBody, {
            ok: true,
            id: 'canonical-result',
          });
        }
      }
    );

    test(
      'same operationId from another actor does not leak stored response',
      async () => {
        const original = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const reserved = await service.reserveOrReplay(original);
        assert.equal(reserved.kind, 'ACQUIRED');
        if (reserved.kind !== 'ACQUIRED') {
          assert.fail('Expected ACQUIRED');
        }

        await prisma.$transaction(async (tx) => {
          await IdempotencyService.completeWithinTransaction(tx, {
            ...original,
            leaseToken: reserved.leaseToken,
            responseStatus: 200,
            responseBody: {
              secretEntityId: randomUUID(),
            },
          });
        });

        const attacker = {
          ...original,
          actorUserId: randomUUID(),
        };

        const result = await service.reserveOrReplay(attacker);

        assert.deepEqual(result, {
          kind: 'KEY_REUSE',
        });
      }
    );

    test(
      'PROCESSING with valid lease returns IN_PROGRESS',
      async () => {
        const input = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const first = await service.reserveOrReplay(input);
        assert.equal(first.kind, 'ACQUIRED');

        const second = await service.reserveOrReplay(input);
        assert.equal(second.kind, 'IN_PROGRESS');
      }
    );

    test(
      'expired PROCESSING lease can be taken over by only one concurrent caller',
      async () => {
        const input = identity();
        const now = new Date();

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

        const winners = [a, b].filter((value) => value !== null);
        assert.equal(winners.length, 1);
      }
    );

    test(
      'expired PROCESSING lease cannot be taken over by another actor or tenant',
      async () => {
        const input = identity();
        const now = new Date();

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
          },
        });

        const service = new IdempotencyService(prisma, 60_000);

        const actorHijack = await service.takeoverExpired({
          ...input,
          actorUserId: randomUUID(),
          now,
        });

        const tenantHijack = await service.takeoverExpired({
          ...input,
          organizationId: randomUUID(),
          now,
        });

        assert.equal(actorHijack, null);
        assert.equal(tenantHijack, null);
      }
    );

    test(
      'COMPLETED transition rolls back with the transaction',
      async () => {
        const input = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const reserved = await service.reserveOrReplay(input);
        assert.equal(reserved.kind, 'ACQUIRED');
        if (reserved.kind !== 'ACQUIRED') {
          assert.fail('Expected ACQUIRED');
        }

        await assert.rejects(
          prisma.$transaction(async (tx) => {
            await IdempotencyService.completeWithinTransaction(tx, {
              ...input,
              leaseToken: reserved.leaseToken,
              responseStatus: 200,
              responseBody: {
                ok: true,
              },
            });

            throw new Error('forced rollback');
          }),
          /forced rollback/
        );

        const stored = await prisma.operationIdempotency.findUniqueOrThrow({
          where: {
            operationId: input.operationId,
          },
        });

        assert.equal(
          stored.status,
          IdempotencyStatus.PROCESSING
        );
        assert.equal(stored.responseStatus, null);
        assert.equal(stored.responseBody, null);
        assert.equal(stored.completedAt, null);
      }
    );

    test(
      'conditional COMPLETED update failure aborts transaction',
      async () => {
        const input = identity();
        const service = new IdempotencyService(prisma, 60_000);

        const reserved = await service.reserveOrReplay(input);
        assert.equal(reserved.kind, 'ACQUIRED');
        if (reserved.kind !== 'ACQUIRED') {
          assert.fail('Expected ACQUIRED');
        }

        await prisma.operationIdempotency.update({
          where: {
            operationId: input.operationId,
          },
          data: {
            requestHash: computeCanonicalHash({
              changed: true,
            }),
          },
        });

        await assert.rejects(
          prisma.$transaction(async (tx) => {
            await IdempotencyService.completeWithinTransaction(tx, {
              ...input,
              leaseToken: reserved.leaseToken,
              responseStatus: 200,
              responseBody: {
                ok: true,
              },
            });
          }),
          /Could not transition/
        );

        const stored = await prisma.operationIdempotency.findUniqueOrThrow({
          where: {
            operationId: input.operationId,
          },
        });

        assert.equal(stored.status, IdempotencyStatus.PROCESSING);
        assert.equal(stored.completedAt, null);
      }
    );
  }
);
