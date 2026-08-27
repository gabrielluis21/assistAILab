import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  randomUUID,
} from 'node:crypto';

import {
  EquipmentOwnerType,
  OperationType,
  Role,
  UserStatus,
} from '@prisma/client';

import type {
  FastifyInstance,
} from 'fastify';

import {
  buildApp,
} from '../../app.js';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  IdempotencyStateConflictError,
} from '../../core/idempotency/idempotency.service.js';

import {
  mapPaymentBoundaryError,
  parseOperationIdHeader,
} from './payments.controller.js';

describe(
  'FIN-F01 remediation security',
  {
    concurrency: false,
  },
  () => {
    let app: FastifyInstance;

    const runId = randomUUID();
    const organizationId = randomUUID();
    const adminId = randomUUID();
    const techId = randomUUID();
    const customerId = randomUUID();
    const customerUserId = randomUUID();
    const equipmentId = randomUUID();
    const serviceOrderId = randomUUID();

    let adminToken: string;
    let techToken: string;
    let customerToken: string;

    const paymentIds: string[] = [];
    const operationIds: string[] = [];
    const syncIds: bigint[] = [];

    function operationId() {
      const id = randomUUID();
      operationIds.push(id);
      return id;
    }

    function auth(token: string) {
      return {
        authorization:
          `Bearer ${token}`,
      };
    }

    async function createPayment(
      token: string,
      amountMinor = 1000
    ) {
      const op = operationId();

      const response =
        await app.inject({
          method: 'POST',
          url: '/api/v1/payments',
          headers: {
            ...auth(token),
            'x-operation-id': op,
          },
          payload: {
            serviceOrderId,
            amountMinor,
            method: 'PIX',
          },
        });

      if (response.statusCode === 201) {
        const id = response.json().payment.id;
        if (!paymentIds.includes(id)) {
          paymentIds.push(id);
        }
      }

      return response;
    }

    before(
      async () => {
        process.env.JWT_SECRET =
          'fin-f01-remediation-test-secret';

        app = buildApp();
        await app.ready();

        await prisma.organization.create({
          data: {
            id: organizationId,
            name:
              `FIN-F01 remediation ${runId}`,
          },
        });

        await prisma.customer.create({
          data: {
            id: customerId,
            name:
              'FIN-F01 remediation customer',
          },
        });

        await prisma.user.createMany({
          data: [
            {
              id: adminId,
              name: 'FIN-F01 admin',
              email:
                `fin-f01-rem-admin-${runId}@test.local`,
              passwordHash: 'unused',
              role: Role.ADMIN,
              status: UserStatus.ACTIVE,
            },
            {
              id: techId,
              name: 'FIN-F01 tech',
              email:
                `fin-f01-rem-tech-${runId}@test.local`,
              passwordHash: 'unused',
              role: Role.TECHNICIAN,
              status: UserStatus.ACTIVE,
            },
            {
              id: customerUserId,
              name: 'FIN-F01 customer',
              email:
                `fin-f01-rem-customer-${runId}@test.local`,
              passwordHash: 'unused',
              role: Role.CUSTOMER,
              status: UserStatus.ACTIVE,
              customerId,
            },
          ],
        });

        await prisma.membership.createMany({
          data: [
            {
              userId: adminId,
              organizationId,
              role: Role.ADMIN,
            },
            {
              userId: techId,
              organizationId,
              role: Role.TECHNICIAN,
            },
          ],
        });

        await prisma.equipment.create({
          data: {
            id: equipmentId,
            customerId,
            ownerType:
              EquipmentOwnerType.CUSTOMER,
            brand: 'FIN',
            model: 'REM',
            type: 'NOTEBOOK',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id: serviceOrderId,
            organizationId,
            customerId,
            equipmentId,
            problemDescription:
              'FIN-F01 remediation',
          },
        });

        adminToken = app.jwt.sign({
          sub: adminId,
          role: 'ADMIN',
          name: 'Admin',
          customerId: null,
          organizationId,
        });

        techToken = app.jwt.sign({
          sub: techId,
          role: 'TECHNICIAN',
          name: 'Tech',
          customerId: null,
          organizationId,
        });

        customerToken = app.jwt.sign({
          sub: customerUserId,
          role: 'CUSTOMER',
          name: 'Customer',
          customerId,
          organizationId: null,
        });
      }
    );

    after(
      async () => {
        await prisma.operationIdempotency.deleteMany({
          where: {
            operationId: {
              in: operationIds,
            },
          },
        });

        if (syncIds.length > 0) {
          await prisma.syncChangeLog.deleteMany({
            where: {
              id: {
                in: syncIds,
              },
            },
          });
        }

        await prisma.syncChangeLog.deleteMany({
          where: {
            entityType: 'PAYMENT',
            entityId: {
              in: paymentIds,
            },
          },
        });

        await prisma.payment.deleteMany({
          where: {
            id: {
              in: paymentIds,
            },
          },
        });

        await prisma.serviceOrder.delete({
          where: {
            id: serviceOrderId,
          },
        });

        await prisma.equipment.delete({
          where: {
            id: equipmentId,
          },
        });

        await prisma.membership.deleteMany({
          where: {
            organizationId,
          },
        });

        await prisma.user.deleteMany({
          where: {
            id: {
              in: [
                adminId,
                techId,
                customerUserId,
              ],
            },
          },
        });

        await prisma.customer.delete({
          where: {
            id: customerId,
          },
        });

        await prisma.organization.delete({
          where: {
            id: organizationId,
          },
        });

        await app.close();
      }
    );

    test(
      'disabled staff user is blocked immediately with an already-issued JWT',
      async () => {
        await prisma.user.update({
          where: { id: techId },
          data: {
            status: UserStatus.DISABLED,
          },
        });

        try {
          const response =
            await createPayment(techToken);

          assert.equal(
            response.statusCode,
            403
          );
        } finally {
          await prisma.user.update({
            where: { id: techId },
            data: {
              status: UserStatus.ACTIVE,
            },
          });
        }
      }
    );

    test(
      'removed Membership blocks financial mutation immediately',
      async () => {
        await prisma.membership.delete({
          where: {
            userId_organizationId: {
              userId: techId,
              organizationId,
            },
          },
        });

        try {
          const response =
            await createPayment(techToken);

          assert.equal(
            response.statusCode,
            403
          );
        } finally {
          await prisma.membership.create({
            data: {
              userId: techId,
              organizationId,
              role: Role.TECHNICIAN,
            },
          });
        }
      }
    );

    test(
      'ADMIN downgrade invalidates old ADMIN token for financial mutation',
      async () => {
        const created =
          await createPayment(adminToken, 2500);

        assert.equal(
          created.statusCode,
          201
        );

        const paymentId =
          created.json().payment.id;

        await prisma.membership.update({
          where: {
            userId_organizationId: {
              userId: adminId,
              organizationId,
            },
          },
          data: {
            role: Role.TECHNICIAN,
          },
        });

        try {
          const response =
            await app.inject({
              method: 'PATCH',
              url:
                `/api/v1/payments/${paymentId}/status`,
              headers: {
                ...auth(adminToken),
                'x-operation-id':
                  operationId(),
              },
              payload: {
                status: 'CONFIRMED',
              },
            });

          assert.equal(
            response.statusCode,
            403
          );
        } finally {
          await prisma.membership.update({
            where: {
              userId_organizationId: {
                userId: adminId,
                organizationId,
              },
            },
            data: {
              role: Role.ADMIN,
            },
          });
        }
      }
    );

    test(
      'CUSTOMER Sync Pull explicitly denies PAYMENT even on authorized entityId collision',
      async () => {
        const cursorBefore =
          (
            await prisma.syncChangeLog.aggregate({
              _max: { id: true },
            })
          )._max.id ?? 0n;

        const injected =
          await prisma.syncChangeLog.create({
            data: {
              cursor: randomUUID(),
              entityType: 'PAYMENT',
              entityId: customerId,
              operationType:
                OperationType.UPDATE,
              data: {
                secret: 'must-not-leak',
              },
            },
          });

        syncIds.push(injected.id);

        await prisma.syncChangeLog.update({
          where: { id: injected.id },
          data: {
            cursor: injected.id.toString(),
          },
        });

        const response =
          await app.inject({
            method: 'GET',
            url:
              `/api/v1/sync/changes?cursor=${cursorBefore.toString()}&limit=20`,
            headers: auth(customerToken),
          });

        assert.equal(
          response.statusCode,
          200
        );

        const changes =
          response.json().changes as Array<{
            entityType: string;
            entityId: string;
          }>;

        assert.equal(
          changes.some(
            (change) =>
              change.entityType.toUpperCase() ===
              'PAYMENT'
          ),
          false
        );
      }
    );

    test(
      'ambiguous comma-joined X-Operation-Id is rejected',
      async () => {
        const response =
          await app.inject({
            method: 'POST',
            url: '/api/v1/payments',
            headers: {
              ...auth(techToken),
              'x-operation-id':
                `${randomUUID()},${randomUUID()}`,
            },
            payload: {
              serviceOrderId,
              amountMinor: 1000,
              method: 'PIX',
            },
          });

        assert.equal(
          response.statusCode,
          400
        );
      }
    );

    test(
      'duplicate X-Operation-Id raw headers are rejected by parser',
      () => {
        const first = randomUUID();
        const second = randomUUID();

        assert.throws(
          () =>
            parseOperationIdHeader(
              first,
              [
                'X-Operation-Id',
                first,
                'x-operation-id',
                second,
              ]
            )
        );
      }
    );

    test(
      'IdempotencyStateConflictError maps to 409 IDEMPOTENCY_STATE_CONFLICT',
      () => {
        assert.deepEqual(
          mapPaymentBoundaryError(
            new IdempotencyStateConflictError()
          ),
          {
            statusCode: 409,
            body: {
              error:
                'IDEMPOTENCY_STATE_CONFLICT',
            },
          }
        );
      }
    );
  }
);
