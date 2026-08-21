import {
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  assertGenericEquipmentSyncPayload,
} from './sync.controller.js';

import bcrypt from 'bcrypt';

import {
  randomUUID,
} from 'node:crypto';

import type {
  FastifyInstance,
} from 'fastify';

import {
  CustomerOrganizationStatus,
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
  {
    concurrency: false,
  },
  () => {
    /**
     * ========================================================
     * T012
     * ========================================================
     *
     * Teste original.
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
     * T030 / C03.07
     * ========================================================
     *
     * Offline-first precisa respeitar a mesma
     * identidade global usada pela API REST.
     *
     * CUSTOMER João possui:
     *
     * Organization A → OS A
     * Organization B → OS B
     *
     * Pull deve devolver ambas.
     *
     * OS de Maria não pode ser devolvida.
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
         * IDS
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
           * ==================================================
           * CURSOR BASE
           * ==================================================
           *
           * Não assumimos banco vazio.
           */
          const latestChange =
            await prisma
              .syncChangeLog
              .findFirst({
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
           * ==================================================
           * ORGANIZATIONS
           * ==================================================
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
           * ==================================================
           * CUSTOMER GLOBAL
           * ==================================================
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

          /**
           * User CUSTOMER ACTIVE.
           *
           * Nenhuma Membership.
           */
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
           * Customer possui relacionamento
           * com duas assistências.
           */
          await prisma.customerOrganization.create({
            data: {
              customerId,

              organizationId:
                organizationAId,

              status:
                CustomerOrganizationStatus.ACTIVE,
            },
          });

          await prisma.customerOrganization.create({
            data: {
              customerId,

              organizationId:
                organizationBId,

              status:
                CustomerOrganizationStatus.ACTIVE,
            },
          });

          /**
           * ==================================================
           * OUTRO CUSTOMER
           * ==================================================
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
                CustomerOrganizationStatus.ACTIVE,
            },
          });

          /**
           * ==================================================
           * EQUIPMENTS
           * ==================================================
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
           * ==================================================
           * SERVICE ORDERS
           * ==================================================
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
           * ==================================================
           * SYNC CHANGE LOG
           * ==================================================
           *
           * Cria três mudanças:
           *
           * João/A
           * João/B
           * Maria/A
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
           * ==================================================
           * APP
           * ==================================================
           */

          app =
            buildApp();

          await app.ready();

          /**
           * ==================================================
           * LOGIN
           * ==================================================
           *
           * Deve funcionar sem Membership.
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

          const loginBody =
            loginResponse.json();

          assert.equal(
            loginBody.user.role,
            Role.CUSTOMER
          );

          assert.equal(
            loginBody.user.customerId,
            customerId
          );

          assert.equal(
            loginBody.user.organizationId,
            null
          );

          const {
            token,
          } =
            loginBody;

          /**
           * ==================================================
           * PULL
           * ==================================================
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

          /**
           * Apenas os IDs devolvidos
           * pelo Sync.
           */
          const receivedIds =
            new Set<string>(
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
           * OS própria na Organization A.
           */
          assert.equal(
            receivedIds.has(
              orderAId
            ),
            true
          );

          /**
           * OS própria na Organization B.
           *
           * Este assert é o principal
           * do C03.07 offline-first.
           */
          assert.equal(
            receivedIds.has(
              orderBId
            ),
            true
          );

          /**
           * OS da Maria nunca pode aparecer.
           */
          assert.equal(
            receivedIds.has(
              otherOrderId
            ),
            false
          );

          /**
           * Confirma que as mudanças recebidas
           * são efetivamente de duas Organizations.
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

          assert.equal(
            ownOrderChanges.length,
            2
          );

          const organizationIds =
            new Set<string>(
              ownOrderChanges.map(
                (
                  change:
                    {
                      data: {
                        organizationId:
                        string;
                      };
                    }
                ) =>
                  change
                    .data
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
           * User precisa sair antes
           * do Customer.
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

    /**
 * ============================================================
 * T037 / C04.08
 * ============================================================
 *
 * O Sync genérico não pode ser usado como atalho
 * para transferir propriedade de Equipment.
 *
 * CUSTOMER → ORGANIZATION
 *
 * deve acontecer exclusivamente através
 * do EquipmentAcquisition.
 */
    test(
      'generic Equipment Sync cannot transfer CUSTOMER ownership to an Organization',
      () => {
        /**
         * Não pode mudar ownerType.
         */
        assert.throws(
          () => {
            assertGenericEquipmentSyncPayload({
              ownerType:
                'ORGANIZATION',

              organizationId:
                '00000000-0000-0000-0000-000000000001',

              organizationPurpose:
                'RESALE',
            });
          },
          /Equipment ownership cannot be transferred through generic Sync/
        );

        /**
         * Mesmo mantendo ownerType CUSTOMER,
         * não pode injetar organizationId.
         */
        assert.throws(
          () => {
            assertGenericEquipmentSyncPayload({
              ownerType:
                'CUSTOMER',

              organizationId:
                '00000000-0000-0000-0000-000000000001',
            });
          },
          /organizationId cannot be assigned to Equipment through generic Sync/
        );

        /**
         * Também não pode atribuir finalidade
         * organizacional pelo Sync genérico.
         */
        assert.throws(
          () => {
            assertGenericEquipmentSyncPayload({
              ownerType:
                'CUSTOMER',

              organizationPurpose:
                'PARTS_DONOR',
            });
          },
          /organizationPurpose cannot be assigned through generic Sync/
        );
      }
    );
  }
);