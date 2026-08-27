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
  IdempotencyStatus,
  PaymentMethod,
  PaymentStatus,
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
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

import {
  IdempotencyService,
  IdempotencyStateConflictError,
} from '../../core/idempotency/idempotency.service.js';

describe(
  'FIN-F01 - Legacy Payment Tenant + Security Hardening',
  {
    concurrency:
      false,
  },
  () => {
    let app:
      FastifyInstance;

    const runId =
      randomUUID();

    const organizationAId =
      randomUUID();

    const organizationBId =
      randomUUID();

    const adminAId =
      randomUUID();

    const adminBId =
      randomUUID();

    const techAId =
      randomUUID();

    const customerUserId =
      randomUUID();

    const customerAId =
      randomUUID();

    const customerBId =
      randomUUID();

    const equipmentAId =
      randomUUID();

    const equipmentBId =
      randomUUID();

    const serviceOrderAId =
      randomUUID();

    const serviceOrderBId =
      randomUUID();

    let adminAToken:
      string;

    let adminBToken:
      string;

    let techAToken:
      string;

    let customerToken:
      string;

    const operationIds:
      string[] =
      [];

    const paymentIds:
      string[] =
      [];

    function op(): string {
      const value =
        randomUUID();

      operationIds.push(
        value
      );

      return value;
    }

    function auth(
      token:
        string
    ) {
      return {
        authorization:
          `Bearer ${token}`,
      };
    }

    async function createPayment(
      token:
        string,
      serviceOrderId:
        string,
      amountMinor =
        12_345,
      operationId =
        op()
    ) {
      const response =
        await app.inject({
          method:
            'POST',
          url:
            '/api/v1/payments',
          headers: {
            ...auth(
              token
            ),
            'x-operation-id':
              operationId,
          },
          payload: {
            serviceOrderId,
            amountMinor,
            method:
              'PIX',
            notes:
              'FIN-F01 test',
          },
        });

      if (
        response.statusCode ===
        201
      ) {
        const id =
          response.json()
            .payment.id;

        if (
          !paymentIds.includes(
            id
          )
        ) {
          paymentIds.push(
            id
          );
        }
      }

      return response;
    }

    before(
      async () => {
        process.env.JWT_SECRET =
          'fin-f01-test-secret-2026';

        app =
          buildApp();

        await app.ready();

        await prisma.organization
          .createMany({
            data: [
              {
                id:
                  organizationAId,
                name:
                  `FIN-F01 Org A ${runId}`,
              },
              {
                id:
                  organizationBId,
                name:
                  `FIN-F01 Org B ${runId}`,
              },
            ],
          });

        await prisma.customer
          .createMany({
            data: [
              {
                id:
                  customerAId,
                name:
                  `FIN-F01 Customer A ${runId}`,
              },
              {
                id:
                  customerBId,
                name:
                  `FIN-F01 Customer B ${runId}`,
              },
            ],
          });

        const users = [
          {
            id:
              adminAId,
            name:
              'FIN-F01 Admin A',
            email:
              `fin-f01-admin-a-${runId}@test.local`,
            passwordHash:
              'not-used',
            role:
              Role.ADMIN,
            status:
              UserStatus.ACTIVE,
          },
          {
            id:
              adminBId,
            name:
              'FIN-F01 Admin B',
            email:
              `fin-f01-admin-b-${runId}@test.local`,
            passwordHash:
              'not-used',
            role:
              Role.ADMIN,
            status:
              UserStatus.ACTIVE,
          },
          {
            id:
              techAId,
            name:
              'FIN-F01 Tech A',
            email:
              `fin-f01-tech-a-${runId}@test.local`,
            passwordHash:
              'not-used',
            role:
              Role.TECHNICIAN,
            status:
              UserStatus.ACTIVE,
          },
          {
            id:
              customerUserId,
            name:
              'FIN-F01 Customer User',
            email:
              `fin-f01-customer-${runId}@test.local`,
            passwordHash:
              'not-used',
            role:
              Role.CUSTOMER,
            status:
              UserStatus.ACTIVE,
            customerId:
              customerAId,
          },
        ];

        await prisma.user
          .createMany({
            data:
              users,
          });

        await prisma.membership
          .createMany({
            data: [
              {
                userId:
                  adminAId,
                organizationId:
                  organizationAId,
                role:
                  Role.ADMIN,
              },
              {
                userId:
                  adminBId,
                organizationId:
                  organizationBId,
                role:
                  Role.ADMIN,
              },
              {
                userId:
                  techAId,
                organizationId:
                  organizationAId,
                role:
                  Role.TECHNICIAN,
              },
            ],
          });

        await prisma.equipment
          .createMany({
            data: [
              {
                id:
                  equipmentAId,
                customerId:
                  customerAId,
                ownerType:
                  EquipmentOwnerType.CUSTOMER,
                brand:
                  'FIN',
                model:
                  'A',
                type:
                  'NOTEBOOK',
              },
              {
                id:
                  equipmentBId,
                customerId:
                  customerBId,
                ownerType:
                  EquipmentOwnerType.CUSTOMER,
                brand:
                  'FIN',
                model:
                  'B',
                type:
                  'NOTEBOOK',
              },
            ],
          });

        await prisma.serviceOrder
          .createMany({
            data: [
              {
                id:
                  serviceOrderAId,
                organizationId:
                  organizationAId,
                customerId:
                  customerAId,
                equipmentId:
                  equipmentAId,
                problemDescription:
                  'FIN-F01 A',
              },
              {
                id:
                  serviceOrderBId,
                organizationId:
                  organizationBId,
                customerId:
                  customerBId,
                equipmentId:
                  equipmentBId,
                problemDescription:
                  'FIN-F01 B',
              },
            ],
          });

        adminAToken =
          app.jwt.sign({
            sub:
              adminAId,
            role:
              'ADMIN',
            name:
              'Admin A',
            customerId:
              null,
            organizationId:
              organizationAId,
          });

        adminBToken =
          app.jwt.sign({
            sub:
              adminBId,
            role:
              'ADMIN',
            name:
              'Admin B',
            customerId:
              null,
            organizationId:
              organizationBId,
          });

        techAToken =
          app.jwt.sign({
            sub:
              techAId,
            role:
              'TECHNICIAN',
            name:
              'Tech A',
            customerId:
              null,
            organizationId:
              organizationAId,
          });

        customerToken =
          app.jwt.sign({
            sub:
              customerUserId,
            role:
              'CUSTOMER',
            name:
              'Customer',
            customerId:
              customerAId,
            organizationId:
              null,
          });
      }
    );

    after(
      async () => {
        await prisma
          .operationIdempotency
          .deleteMany({
            where: {
              OR: [
                {
                  operationId: {
                    in:
                      operationIds,
                  },
                },
                {
                  command: {
                    in: [
                      'PAYMENT_CREATE',
                      'PAYMENT_CONFIRM',
                      'PAYMENT_CANCEL',
                      'FIN_F01_STALE_TEST',
                    ],
                  },
                  userId: {
                    in: [
                      adminAId,
                      adminBId,
                      techAId,
                    ],
                  },
                },
              ],
            },
          });

        await prisma.syncChangeLog
          .deleteMany({
            where: {
              entityType:
                'PAYMENT',
              entityId: {
                in:
                  paymentIds,
              },
            },
          });

        await prisma.payment
          .deleteMany({
            where: {
              OR: [
                {
                  id: {
                    in:
                      paymentIds,
                  },
                },
                {
                  organizationId: {
                    in: [
                      organizationAId,
                      organizationBId,
                    ],
                  },
                },
              ],
            },
          });

        await prisma.serviceOrder
          .deleteMany({
            where: {
              id: {
                in: [
                  serviceOrderAId,
                  serviceOrderBId,
                ],
              },
            },
          });

        await prisma.equipment
          .deleteMany({
            where: {
              id: {
                in: [
                  equipmentAId,
                  equipmentBId,
                ],
              },
            },
          });

        await prisma.membership
          .deleteMany({
            where: {
              userId: {
                in: [
                  adminAId,
                  adminBId,
                  techAId,
                ],
              },
            },
          });

        await prisma.user
          .deleteMany({
            where: {
              id: {
                in: [
                  adminAId,
                  adminBId,
                  techAId,
                  customerUserId,
                ],
              },
            },
          });

        await prisma.customer
          .deleteMany({
            where: {
              id: {
                in: [
                  customerAId,
                  customerBId,
                ],
              },
            },
          });

        await prisma.organization
          .deleteMany({
            where: {
              id: {
                in: [
                  organizationAId,
                  organizationBId,
                ],
              },
            },
          });

        await app.close();
      }
    );

    test(
      'CUSTOMER gets 403 for every Payment REST surface',
      async () => {
        const list =
          await app.inject({
            method:
              'GET',
            url:
              '/api/v1/payments',
            headers:
              auth(
                customerToken
              ),
          });

        const summary =
          await app.inject({
            method:
              'GET',
            url:
              '/api/v1/payments/summary',
            headers:
              auth(
                customerToken
              ),
          });

        const create =
          await createPayment(
            customerToken,
            serviceOrderAId
          );

        assert.equal(
          list.statusCode,
          403
        );

        assert.equal(
          summary.statusCode,
          403
        );

        assert.equal(
          create.statusCode,
          403
        );
      }
    );

    test(
      'TECH can CREATE PENDING and tenant/customer come from ServiceOrder authority',
      async () => {
        const response =
          await createPayment(
            techAToken,
            serviceOrderAId,
            25_050
          );

        assert.equal(
          response.statusCode,
          201
        );

        const payment =
          response.json()
            .payment;

        assert.equal(
          payment.organizationId,
          organizationAId
        );

        assert.equal(
          payment.customerId,
          customerAId
        );

        assert.equal(
          payment.amountMinor,
          25_050
        );

        assert.equal(
          payment.status,
          'PENDING'
        );

        assert.equal(
          payment.createdByUserId,
          techAId
        );

        assert.equal(
          payment.version,
          1
        );

        assert.equal(
          'amount' in payment,
          false
        );
      }
    );

    test(
      'strict CREATE DTO rejects identity/customer/status/float-money injection and long notes',
      async () => {
        const cases = [
          {
            serviceOrderId:
              serviceOrderAId,
            amountMinor:
              1_000,
            method:
              'PIX',
            id:
              randomUUID(),
          },
          {
            serviceOrderId:
              serviceOrderAId,
            amountMinor:
              1_000,
            method:
              'PIX',
            customerId:
              customerBId,
          },
          {
            serviceOrderId:
              serviceOrderAId,
            amountMinor:
              1_000,
            method:
              'PIX',
            status:
              'CONFIRMED',
          },
          {
            serviceOrderId:
              serviceOrderAId,
            amountMinor:
              10.5,
            method:
              'PIX',
          },
          {
            serviceOrderId:
              serviceOrderAId,
            amountMinor:
              1_000,
            method:
              'PIX',
            notes:
              'x'.repeat(
                1001
              ),
          },
        ];

        for (
          const payload of
          cases
        ) {
          const response =
            await app.inject({
              method:
                'POST',
              url:
                '/api/v1/payments',
              headers: {
                ...auth(
                  techAToken
                ),
                'x-operation-id':
                  op(),
              },
              payload,
            });

          assert.equal(
            response.statusCode,
            400
          );
        }
      }
    );

    test(
      'tenant isolation prevents list/get/create cross-tenant access before idempotency',
      async () => {
        const paymentB =
          await createPayment(
            adminBToken,
            serviceOrderBId,
            7_700
          );

        assert.equal(
          paymentB.statusCode,
          201
        );

        const paymentBId =
          paymentB.json()
            .payment.id;

        const listA =
          await app.inject({
            method:
              'GET',
            url:
              '/api/v1/payments',
            headers:
              auth(
                adminAToken
              ),
          });

        assert.equal(
          listA.statusCode,
          200
        );

        assert.equal(
          listA
            .json()
            .payments
            .some(
              (
                item:
                  { id: string }
              ) =>
                item.id ===
                paymentBId
            ),
          false
        );

        const getA =
          await app.inject({
            method:
              'GET',
            url:
              `/api/v1/payments/${paymentBId}`,
            headers:
              auth(
                adminAToken
              ),
          });

        assert.equal(
          getA.statusCode,
          404
        );

        const attackOp =
          op();

        const validA =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            2_000,
            attackOp
          );

        assert.equal(
          validA.statusCode,
          201
        );

        const crossTenantReplay =
          await createPayment(
            adminBToken,
            serviceOrderAId,
            2_000,
            attackOp
          );

        assert.equal(
          crossTenantReplay.statusCode,
          404
        );
      }
    );

    test(
      'CREATE replay returns the same server-generated Payment and key reuse conflicts',
      async () => {
        const operationId =
          op();

        const first =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            9_999,
            operationId
          );

        const replay =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            9_999,
            operationId
          );

        assert.equal(
          first.statusCode,
          201
        );

        assert.equal(
          replay.statusCode,
          201
        );

        assert.equal(
          replay.json()
            .payment.id,
          first.json()
            .payment.id
        );

        const reused =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            10_000,
            operationId
          );

        assert.equal(
          reused.statusCode,
          409
        );

        const count =
          await prisma.payment
            .count({
              where: {
                clientOperationId:
                  operationId,
              },
            });

        assert.equal(
          count,
          1
        );
      }
    );

    test(
      'TECH cannot CONFIRM, CANCEL, or SUMMARY',
      async () => {
        const created =
          await createPayment(
            techAToken,
            serviceOrderAId
          );

        const id =
          created.json()
            .payment.id;

        const confirm =
          await app.inject({
            method:
              'PATCH',
            url:
              `/api/v1/payments/${id}/status`,
            headers: {
              ...auth(
                techAToken
              ),
              'x-operation-id':
                op(),
            },
            payload: {
              status:
                'CONFIRMED',
            },
          });

        const cancel =
          await app.inject({
            method:
              'PATCH',
            url:
              `/api/v1/payments/${id}/status`,
            headers: {
              ...auth(
                techAToken
              ),
              'x-operation-id':
                op(),
            },
            payload: {
              status:
                'CANCELLED',
            },
          });

        const summary =
          await app.inject({
            method:
              'GET',
            url:
              '/api/v1/payments/summary',
            headers:
              auth(
                techAToken
              ),
          });

        assert.equal(
          confirm.statusCode,
          403
        );

        assert.equal(
          cancel.statusCode,
          403
        );

        assert.equal(
          summary.statusCode,
          403
        );
      }
    );

    test(
      'ADMIN confirmation is fenced/idempotent; replay wins after mutable state changed',
      async () => {
        const created =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            3_300
          );

        const id =
          created.json()
            .payment.id;

        const operationId =
          op();

        const confirm =
          await app.inject({
            method:
              'PATCH',
            url:
              `/api/v1/payments/${id}/status`,
            headers: {
              ...auth(
                adminAToken
              ),
              'x-operation-id':
                operationId,
            },
            payload: {
              status:
                'CONFIRMED',
            },
          });

        assert.equal(
          confirm.statusCode,
          200
        );

        assert.equal(
          confirm.json()
            .payment.status,
          'CONFIRMED'
        );

        assert.equal(
          confirm.json()
            .payment.confirmedByUserId,
          adminAId
        );

        const replay =
          await app.inject({
            method:
              'PATCH',
            url:
              `/api/v1/payments/${id}/status`,
            headers: {
              ...auth(
                adminAToken
              ),
              'x-operation-id':
                operationId,
            },
            payload: {
              status:
                'CONFIRMED',
            },
          });

        assert.equal(
          replay.statusCode,
          200
        );

        assert.deepEqual(
          replay.json(),
          confirm.json()
        );

        const refunded =
          await app.inject({
            method:
              'PATCH',
            url:
              `/api/v1/payments/${id}/status`,
            headers: {
              ...auth(
                adminAToken
              ),
              'x-operation-id':
                op(),
            },
            payload: {
              status:
                'REFUNDED',
            },
          });

        const paidAtInjection =
          await app.inject({
            method:
              'PATCH',
            url:
              `/api/v1/payments/${id}/status`,
            headers: {
              ...auth(
                adminAToken
              ),
              'x-operation-id':
                op(),
            },
            payload: {
              status:
                'CONFIRMED',
              paidAt:
                new Date()
                  .toISOString(),
            },
          });

        assert.equal(
          refunded.statusCode,
          400
        );

        assert.equal(
          paidAtInjection.statusCode,
          400
        );
      }
    );

    test(
      'concurrent status commands use CAS: exactly one succeeds',
      async () => {
        const created =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            4_400
          );

        const id =
          created.json()
            .payment.id;

        const requests = [
          op(),
          op(),
        ].map(
          (
            operationId
          ) =>
            app.inject({
              method:
                'PATCH',
              url:
                `/api/v1/payments/${id}/status`,
              headers: {
                ...auth(
                  adminAToken
                ),
                'x-operation-id':
                  operationId,
              },
              payload: {
                status:
                  'CONFIRMED',
              },
            })
        );

        const responses =
          await Promise.all(
            requests
          );

        const statuses =
          responses
            .map(
              (
                response
              ) =>
                response
                  .statusCode
            )
            .sort();

        assert.deepEqual(
          statuses,
          [
            200,
            409,
          ]
        );

        const persisted =
          await prisma.payment
            .findUniqueOrThrow({
              where: {
                id,
              },
            });

        assert.equal(
          persisted.status,
          PaymentStatus.CONFIRMED
        );

        assert.equal(
          persisted.version,
          2
        );
      }
    );

    test(
      'stale fenced worker cannot commit Payment mutation',
      async () => {
        const payment =
          await prisma.payment
            .create({
              data: {
                organizationId:
                  organizationAId,
                serviceOrderId:
                  serviceOrderAId,
                customerId:
                  customerAId,
                clientOperationId:
                  `test:${randomUUID()}`,
                amount:
                  11,
                method:
                  PaymentMethod.PIX,
                status:
                  PaymentStatus.PENDING,
                createdByUserId:
                  adminAId,
              },
            });

        paymentIds.push(
          payment.id
        );

        const operationId =
          op();

        const command =
          'FIN_F01_STALE_TEST';

        const endpoint =
          `/api/v1/payments/${payment.id}/status`;

        const requestHash =
          computeCanonicalHash({
            paymentId:
              payment.id,
            status:
              'CONFIRMED',
          });

        await prisma
          .operationIdempotency
          .create({
            data: {
              operationId,
              userId:
                adminAId,
              organizationId:
                organizationAId,
              command,
              endpoint,
              requestHash,
              status:
                IdempotencyStatus.PROCESSING,
              processingExpiresAt:
                new Date(
                  Date.now() +
                  60_000
                ),
              leaseToken:
                'current-owner-token',
            },
          });

        await assert.rejects(
          prisma.$transaction(
            async (tx) => {
              const changed =
                await tx.payment
                  .updateMany({
                    where: {
                      id:
                        payment.id,
                      organizationId:
                        organizationAId,
                      status:
                        PaymentStatus.PENDING,
                      version:
                        1,
                    },
                    data: {
                      status:
                        PaymentStatus.CONFIRMED,
                      version: {
                        increment:
                          1,
                      },
                    },
                  });

              assert.equal(
                changed.count,
                1
              );

              await IdempotencyService
                .completeWithinTransaction(
                  tx,
                  {
                    operationId,
                    actorUserId:
                      adminAId,
                    organizationId:
                      organizationAId,
                    command,
                    endpoint,
                    requestHash,
                    leaseToken:
                      'stale-owner-token',
                    responseStatus:
                      200,
                    responseBody: {
                      ok:
                        true,
                    },
                  }
                );
            }
          ),
          IdempotencyStateConflictError
        );

        const after =
          await prisma.payment
            .findUniqueOrThrow({
              where: {
                id:
                  payment.id,
              },
            });

        assert.equal(
          after.status,
          PaymentStatus.PENDING
        );

        assert.equal(
          after.version,
          1
        );
      }
    );

    test(
      'ADMIN summary is organization scoped and returns minor units',
      async () => {
        const pendingA =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            5_500
          );

        const confirmedA =
          await createPayment(
            adminAToken,
            serviceOrderAId,
            6_600
          );

        const confirmedB =
          await createPayment(
            adminBToken,
            serviceOrderBId,
            99_900
          );

        for (
          const [
            token,
            response,
          ] of [
            [
              adminAToken,
              confirmedA,
            ],
            [
              adminBToken,
              confirmedB,
            ],
          ] as const
        ) {
          const id =
            response.json()
              .payment.id;

          const confirmed =
            await app.inject({
              method:
                'PATCH',
              url:
                `/api/v1/payments/${id}/status`,
              headers: {
                ...auth(
                  token
                ),
                'x-operation-id':
                  op(),
              },
              payload: {
                status:
                  'CONFIRMED',
              },
            });

          assert.equal(
            confirmed.statusCode,
            200
          );
        }

        assert.equal(
          pendingA.statusCode,
          201
        );

        const summary =
          await app.inject({
            method:
              'GET',
            url:
              '/api/v1/payments/summary',
            headers:
              auth(
                adminAToken
              ),
          });

        assert.equal(
          summary.statusCode,
          200
        );

        const body =
          summary.json();

        assert.equal(
          Number.isSafeInteger(
            body.totalRevenueMinor
          ),
          true
        );

        assert.equal(
          Number.isSafeInteger(
            body.pendingAmountMinor
          ),
          true
        );

        assert.ok(
          body.pendingAmountMinor >=
            5_500
        );

        assert.ok(
          body.totalRevenueMinor <
            99_900
        );
      }
    );
  }
);
