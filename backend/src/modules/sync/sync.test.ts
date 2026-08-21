import {
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import bcrypt from 'bcrypt';

import {
  randomUUID,
} from 'node:crypto';

import type {
  FastifyInstance,
} from 'fastify';

import {
  EquipmentOwnerType,
  OperationType,
  Role,
  UserStatus,
} from '@prisma/client';

import {
  buildApp,
} from '../../app.js';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  computePayloadHash,
} from '../../core/middleware/idempotency.middleware.js';

/**
 * ============================================================
 * SYNC ENGINE / IDEMPOTENCY
 * ============================================================
 */
describe(
  'Sync Engine & Idempotency Hardening',
  () => {
    /**
     * Teste original.
     *
     * NÃO remover.
     */
    test(
      'computePayloadHash generates deterministic SHA-256 string',
      () => {
        const payloadA = {
          name:
            'Customer A',

          email:
            'a@example.com',
        };

        const payloadB = {
          name:
            'Customer A',

          email:
            'a@example.com',
        };

        const payloadC = {
          name:
            'Customer B',

          email:
            'b@example.com',
        };

        const hashA =
          computePayloadHash(
            payloadA
          );

        const hashB =
          computePayloadHash(
            payloadB
          );

        const hashC =
          computePayloadHash(
            payloadC
          );

        assert.equal(
          hashA.length,
          64
        );

        assert.equal(
          hashA,
          hashB
        );

        assert.notEqual(
          hashA,
          hashC
        );
      }
    );

    /**
     * ========================================================
     * C03.07 — OFFLINE-FIRST
     * ========================================================
     *
     * API REST:
     *
     * CUSTOMER vê todas as próprias OS.
     *
     * Portanto o Sync Pull precisa obedecer
     * exatamente à mesma regra.
     *
     * Customer
     *   ├── OS Organization A
     *   └── OS Organization B
     *
     * ambas devem ser sincronizadas.
     */
    test(
      'CUSTOMER Sync Pull returns own Service Orders from multiple Organizations and excludes other Customers',
      async () => {
        const runId =
          randomUUID();

        let app:
          FastifyInstance | undefined;

        let oldJwtSecret:
          string | undefined;

        /**
         * ====================================================
         * FIXTURE IDS
         * ====================================================
         */

        const organizationAId =
          randomUUID();

        const organizationBId =
          randomUUID();

        const customerId =
          randomUUID();

        const customerUserId =
          randomUUID();

        const otherCustomerId =
          randomUUID();

        const equipmentAId =
          randomUUID();

        const equipmentBId =
          randomUUID();

        const otherEquipmentId =
          randomUUID();

        const orderAId =
          randomUUID();

        const orderBId =
          randomUUID();

        const otherOrderId =
          randomUUID();

        const customerEmail =
          `c3-sync-${runId}@assistailab.test`;

        const customerPassword =
          'C3-Sync@123456';

        try {
          oldJwtSecret =
            process.env.JWT_SECRET;

          process.env.JWT_SECRET =
            'c3-sync-test-secret-2026';

          const passwordHash =
            await bcrypt.hash(
              customerPassword,
              12
            );

          /**
           * Precisamos do cursor existente
           * antes de gerar nossos logs.
           *
           * Isso evita depender de um banco
           * completamente vazio.
           */
          const latestChange =
            await prisma.syncChangeLog.findFirst({
              orderBy: {
                id:
                  'desc',
              },

              select: {
                id:
                  true,
              },
            });

          const baselineCursor =
            latestChange
              ?.id
              .toString() ??
            '0';

          /**
           * --------------------------------------------------
           * ORGANIZATIONS
           * --------------------------------------------------
           */

          await prisma.organization.create({
            data: {
              id:
                organizationAId,

              name:
                `C3 Sync Organization A ${runId}`,
            },
          });

          await prisma.organization.create({
            data: {
              id:
                organizationBId,

              name:
                `C3 Sync Organization B ${runId}`,
            },
          });

          /**
           * --------------------------------------------------
           * CUSTOMER
           * --------------------------------------------------
           */

          await prisma.customer.create({
            data: {
              id:
                customerId,

              name:
                'C3 Sync Customer',

              email:
                customerEmail,
            },
          });

          await prisma.user.create({
            data: {
              id:
                customerUserId,

              name:
                'C3 Sync Customer',

              email:
                customerEmail,

              passwordHash,

              role:
                Role.CUSTOMER,

              status:
                UserStatus.ACTIVE,

              customerId,
            },
          });

          /**
           * Nenhuma Membership é criada.
           *
           * Customer é global.
           */

          await prisma.customerOrganization.create({
            data: {
              customerId,

              organizationId:
                organizationAId,

              status:
                'ACTIVE',
            },
          });

          await prisma.customerOrganization.create({
            data: {
              customerId,

              organizationId:
                organizationBId,

              status:
                'ACTIVE',
            },
          });

          /**
           * --------------------------------------------------
           * OUTRO CUSTOMER
           * --------------------------------------------------
           */

          await prisma.customer.create({
            data: {
              id:
                otherCustomerId,

              name:
                'C3 Sync Other Customer',

              email:
                `c3-sync-other-${runId}@assistailab.test`,
            },
          });

          await prisma.customerOrganization.create({
            data: {
              customerId:
                otherCustomerId,

              organizationId:
                organizationAId,

              status:
                'ACTIVE',
            },
          });

          /**
           * --------------------------------------------------
           * EQUIPMENTS
           * --------------------------------------------------
           */

          await prisma.equipment.create({
            data: {
              id:
                equipmentAId,

              customerId,

              organizationId:
                null,

              ownerType:
                EquipmentOwnerType.CUSTOMER,

              organizationPurpose:
                null,

              type:
                'NOTEBOOK',

              brand:
                'Dell',

              model:
                'C3 Sync A',
            },
          });

          await prisma.equipment.create({
            data: {
              id:
                equipmentBId,

              customerId,

              organizationId:
                null,

              ownerType:
                EquipmentOwnerType.CUSTOMER,

              organizationPurpose:
                null,

              type:
                'CELULAR',

              brand:
                'Samsung',

              model:
                'C3 Sync B',
            },
          });

          await prisma.equipment.create({
            data: {
              id:
                otherEquipmentId,

              customerId:
                otherCustomerId,

              organizationId:
                null,

              ownerType:
                EquipmentOwnerType.CUSTOMER,

              organizationPurpose:
                null,

              type:
                'NOTEBOOK',

              brand:
                'Acer',

              model:
                'C3 Sync Other',
            },
          });

          /**
           * --------------------------------------------------
           * SERVICE ORDERS
           * --------------------------------------------------
           */

          await prisma.serviceOrder.create({
            data: {
              id:
                orderAId,

              organizationId:
                organizationAId,

              customerId,

              equipmentId:
                equipmentAId,

              problemDescription:
                'C3 Sync OS Organization A',
            },
          });

          await prisma.serviceOrder.create({
            data: {
              id:
                orderBId,

              organizationId:
                organizationBId,

              customerId,

              equipmentId:
                equipmentBId,

              problemDescription:
                'C3 Sync OS Organization B',
            },
          });

          await prisma.serviceOrder.create({
            data: {
              id:
                otherOrderId,

              organizationId:
                organizationAId,

              customerId:
                otherCustomerId,

              equipmentId:
                otherEquipmentId,

              problemDescription:
                'C3 Sync OS de outro Customer',
            },
          });

          /**
           * --------------------------------------------------
           * CHANGE LOG
           * --------------------------------------------------
           *
           * Simulamos mudanças que o dispositivo
           * precisa receber via Pull.
           */

          await prisma.syncChangeLog.create({
            data: {
              cursor:
                randomUUID(),

              entityType:
                'SERVICE_ORDER',

              entityId:
                orderAId,

              operationType:
                OperationType.CREATE,

              data: {
                id:
                  orderAId,

                organizationId:
                  organizationAId,

                customerId,
              },
            },
          });

          await prisma.syncChangeLog.create({
            data: {
              cursor:
                randomUUID(),

              entityType:
                'SERVICE_ORDER',

              entityId:
                orderBId,

              operationType:
                OperationType.CREATE,

              data: {
                id:
                  orderBId,

                organizationId:
                  organizationBId,

                customerId,
              },
            },
          });

          await prisma.syncChangeLog.create({
            data: {
              cursor:
                randomUUID(),

              entityType:
                'SERVICE_ORDER',

              entityId:
                otherOrderId,

              operationType:
                OperationType.CREATE,

              data: {
                id:
                  otherOrderId,

                organizationId:
                  organizationAId,

                customerId:
                  otherCustomerId,
              },
            },
          });

          /**
           * --------------------------------------------------
           * APP
           * --------------------------------------------------
           */

          app =
            buildApp();

          await app.ready();

          /**
           * CUSTOMER autentica sem Membership.
           */
          const loginResponse =
            await app.inject({
              method:
                'POST',

              url:
                '/api/v1/auth/login',

              payload: {
                email:
                  customerEmail,

                password:
                  customerPassword,
              },
            });

          assert.equal(
            loginResponse.statusCode,
            200
          );

          const {
            token,
          } =
            loginResponse.json();

          /**
           * --------------------------------------------------
           * PULL
           * --------------------------------------------------
           */

          const pullResponse =
            await app.inject({
              method:
                'GET',

              url:
                `/api/v1/sync/changes?cursor=${baselineCursor}&limit=100`,

              headers: {
                authorization:
                  `Bearer ${token}`,
              },
            });

          assert.equal(
            pullResponse.statusCode,
            200
          );

          const body =
            pullResponse.json();

          assert.ok(
            Array.isArray(
              body.changes
            )
          );

          const receivedIds =
            new Set(
              body.changes.map(
                (
                  change:
                    {
                      entityId:
                      string;
                    }
                ) =>
                  change.entityId
              )
            );

          /**
           * Próprias OS de A e B.
           */
          assert.equal(
            receivedIds.has(
              orderAId
            ),
            true
          );

          assert.equal(
            receivedIds.has(
              orderBId
            ),
            true
          );

          /**
           * OS de outro Customer
           * não é sincronizada.
           */
          assert.equal(
            receivedIds.has(
              otherOrderId
            ),
            false
          );

          /**
           * Confirma também que os dois
           * registros recebidos realmente
           * representam Organizations distintas.
           */

          const ownOrderChanges =
            body.changes.filter(
              (
                change:
                  {
                    entityId:
                    string;
                  }
              ) =>
                change.entityId ===
                orderAId ||
                change.entityId ===
                orderBId
            );

          const organizationIds =
            new Set(
              ownOrderChanges.map(
                (
                  change:
                    {
                      data:
                      {
                        organizationId:
                        string;
                      };
                    }
                ) =>
                  change.data
                    .organizationId
              )
            );

          assert.equal(
            organizationIds.has(
              organizationAId
            ),
            true
          );

          assert.equal(
            organizationIds.has(
              organizationBId
            ),
            true
          );
        } finally {
          /**
           * ==================================================
           * CLEANUP
           * ==================================================
           */

          await prisma.syncChangeLog.deleteMany({
            where: {
              entityId: {
                in: [
                  orderAId,
                  orderBId,
                  otherOrderId,
                ],
              },
            },
          });

          await prisma.serviceOrder.deleteMany({
            where: {
              id: {
                in: [
                  orderAId,
                  orderBId,
                  otherOrderId,
                ],
              },
            },
          });

          await prisma.equipment.deleteMany({
            where: {
              id: {
                in: [
                  equipmentAId,
                  equipmentBId,
                  otherEquipmentId,
                ],
              },
            },
          });

          /**
           * User antes de Customer,
           * devido à relação customerId.
           */
          await prisma.user.deleteMany({
            where: {
              id:
                customerUserId,
            },
          });

          await prisma.customerOrganization.deleteMany({
            where: {
              customerId: {
                in: [
                  customerId,
                  otherCustomerId,
                ],
              },
            },
          });

          await prisma.customer.deleteMany({
            where: {
              id: {
                in: [
                  customerId,
                  otherCustomerId,
                ],
              },
            },
          });

          await prisma.organization.deleteMany({
            where: {
              id: {
                in: [
                  organizationAId,
                  organizationBId,
                ],
              },
            },
          });

          if (app) {
            await app.close();
          }

          if (oldJwtSecret) {
            process.env.JWT_SECRET =
              oldJwtSecret;
          } else {
            delete process.env.JWT_SECRET;
          }
        }
      }
    );
  }
);
