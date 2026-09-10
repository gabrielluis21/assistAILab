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
  CustomerEventType,
  CustomerOrganizationStatus,
  EquipmentOwnerType,
  OperationType,
  Role,
  ServiceOrderStatus,
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


    /**
     * ========================================================
     * T049 — PART PULL
     * ========================================================
     *
     * Part é global no schema atual e o frontend possui
     * suporte explícito a PART no SyncEngine.
     *
     * ADMIN/TECH precisam receber mudanças de Part.
     */
    test(
      'ADMIN Sync Pull includes global PART changes',
      async () => {
        const runId =
          randomUUID();

        const organizationId =
          randomUUID();

        const adminId =
          randomUUID();

        const partId =
          randomUUID();

        const adminEmail =
          `sync-part-${runId}@assistailab.test`;

        const password =
          'Sync-Part@123456';

        let app:
          FastifyInstance | undefined;

        let oldJwtSecret:
          string | undefined;

        try {
          oldJwtSecret =
            process.env.JWT_SECRET;

          process.env.JWT_SECRET =
            'sync-part-test-secret-2026';

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

          const passwordHash =
            await bcrypt.hash(
              password,
              12
            );

          await prisma.organization.create({
            data: {
              id:
                organizationId,

              name:
                `Sync Part Organization ${runId}`,
            },
          });

          await prisma.user.create({
            data: {
              id:
                adminId,

              name:
                'Sync Part Admin',

              email:
                adminEmail,

              passwordHash,

              role:
                Role.ADMIN,

              status:
                UserStatus.ACTIVE,
            },
          });

          await prisma.membership.create({
            data: {
              userId:
                adminId,

              organizationId,

              role:
                Role.ADMIN,
            },
          });

          await prisma.part.create({
            data: {
              id:
                partId,

              name:
                'Sync Test Part',

              sku:
                `SYNC-PART-${runId}`,

              price:
                100,

              costPrice:
                50,

              stockQuantity:
                4,
            },
          });

          await prisma.syncChangeLog.create({
            data: {
              cursor:
                randomUUID(),

              entityType:
                'PART',

              entityId:
                partId,

              operationType:
                OperationType.CREATE,

              data: {
                id:
                  partId,

                name:
                  'Sync Test Part',

                sku:
                  `SYNC-PART-${runId}`,

                price:
                  100,

                costPrice:
                  50,

                stockQuantity:
                  4,
              },
            },
          });

          app =
            buildApp();

          await app.ready();

          const loginResponse =
            await app.inject({
              method:
                'POST',

              url:
                '/api/v1/auth/login',

              payload: {
                email:
                  adminEmail,

                password,
              },
            });

          assert.equal(
            loginResponse.statusCode,
            200
          );

          const token =
            loginResponse
              .json()
              .token;

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

          const receivedIds =
            new Set<string>(
              pullResponse
                .json()
                .changes
                .map(
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

          assert.equal(
            receivedIds.has(
              partId
            ),
            true
          );
        } finally {
          await prisma.syncChangeLog.deleteMany({
            where: {
              entityId:
                partId,
            },
          });

          await prisma.part.deleteMany({
            where: {
              id:
                partId,
            },
          });

          await prisma.membership.deleteMany({
            where: {
              userId:
                adminId,
            },
          });

          await prisma.user.deleteMany({
            where: {
              id:
                adminId,
            },
          });

          await prisma.organization.deleteMany({
            where: {
              id:
                organizationId,
            },
          });

          if (app) {
            await app.close();
          }

          if (oldJwtSecret) {
            process.env.JWT_SECRET =
              oldJwtSecret;
          } else {
            delete process
              .env
              .JWT_SECRET;
          }
        }
      }
    );

    /**
     * ========================================================
     * T050 — CURSOR ADVANCEMENT
     * ========================================================
     *
     * Um lote pode conter somente mudanças que o usuário
     * não está autorizado a receber.
     *
     * Mesmo assim o cursor precisa avançar sobre o lote
     * já examinado, evitando loop infinito.
     */
    test(
      'Sync Pull advances cursor across an unauthorized-only batch',
      async () => {
        const runId =
          randomUUID();

        const organizationAId =
          randomUUID();

        const organizationBId =
          randomUUID();

        const adminId =
          randomUUID();

        const foreignCustomerId =
          randomUUID();

        const adminEmail =
          `sync-cursor-${runId}@example.com`;

        const password =
          'Sync-Cursor@123456';

        let app:
          FastifyInstance | undefined;

        let oldJwtSecret:
          string | undefined;

        let unauthorizedChangeId:
          bigint | undefined;

        try {
          oldJwtSecret =
            process.env.JWT_SECRET;

          process.env.JWT_SECRET =
            'sync-cursor-test-secret-2026';

          const passwordHash =
            await bcrypt.hash(
              password,
              12
            );

          await prisma.organization.createMany({
            data: [
              {
                id:
                  organizationAId,

                name:
                  `Cursor Organization A ${runId}`,
              },

              {
                id:
                  organizationBId,

                name:
                  `Cursor Organization B ${runId}`,
              },
            ],
          });

          await prisma.user.create({
            data: {
              id:
                adminId,

              name:
                'Cursor Admin',

              email:
                adminEmail,

              passwordHash,

              role:
                Role.ADMIN,

              status:
                UserStatus.ACTIVE,
            },
          });

          await prisma.membership.create({
            data: {
              userId:
                adminId,

              organizationId:
                organizationAId,

              role:
                Role.ADMIN,
            },
          });

          await prisma.customer.create({
            data: {
              id:
                foreignCustomerId,

              name:
                'Foreign Customer',
            },
          });

          await prisma.customerOrganization.create({
            data: {
              customerId:
                foreignCustomerId,

              organizationId:
                organizationBId,

              status:
                CustomerOrganizationStatus.ACTIVE,
            },
          });

          const unauthorizedChange =
            await prisma.syncChangeLog.create({
              data: {
                cursor:
                  randomUUID(),

                entityType:
                  'CUSTOMER',

                entityId:
                  foreignCustomerId,

                operationType:
                  OperationType.CREATE,

                data: {
                  id:
                    foreignCustomerId,

                  name:
                    'Foreign Customer',
                },
              },
            });

          unauthorizedChangeId =
            unauthorizedChange.id;
          /**
           * T050_CONCURRENCY_STABLE_CURSOR
           *
           * O cursor-base aponta para o registro imediatamente
           * anterior ao change criado pelo proprio teste.
           *
           * Isso elimina a race entre a leitura do cursor e
           * inserts concorrentes de outros testes.
           */
          const baselineCursor =
            (
              unauthorizedChange.id -
              1n
            ).toString();

          app =
            buildApp();

          await app.ready();

          const loginResponse =
            await app.inject({
              method:
                'POST',

              url:
                '/api/v1/auth/login',

              payload: {
                email:
                  adminEmail,

                password,
              },
            });

          assert.equal(
            loginResponse.statusCode,
            200
          );

          const token =
            loginResponse
              .json()
              .token;

          const pullResponse =
            await app.inject({
              method:
                'GET',

              url:
                `/api/v1/sync/changes?cursor=${baselineCursor}&limit=1`,

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

          assert.equal(
            body.changes.length,
            0
          );

          assert.equal(
            body.nextCursor,
            unauthorizedChange.id.toString()
          );

          assert.notEqual(
            body.nextCursor,
            baselineCursor
          );
        } finally {
          if (
            unauthorizedChangeId
          ) {
            await prisma.syncChangeLog.deleteMany({
              where: {
                id:
                  unauthorizedChangeId,
              },
            });
          }

          await prisma.customerOrganization.deleteMany({
            where: {
              customerId:
                foreignCustomerId,
            },
          });

          await prisma.customer.deleteMany({
            where: {
              id:
                foreignCustomerId,
            },
          });

          await prisma.membership.deleteMany({
            where: {
              userId:
                adminId,
            },
          });

          await prisma.user.deleteMany({
            where: {
              id:
                adminId,
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
            delete process
              .env
              .JWT_SECRET;
          }
        }
      }
    );
  }
);

/**
 * ============================================================
 * T053 — IDEMPOTENCY FAILURE RETRY
 * ============================================================
 */
test(
  'FAILED Sync operation does not become a false SYNCED replay',
  async () => {
    const runId =
      randomUUID();

    const organizationId =
      randomUUID();

    const customerId =
      randomUUID();

    const equipmentId =
      randomUUID();

    const orderId =
      randomUUID();

    const adminId =
      randomUUID();

    const operationId =
      randomUUID();

    const email =
      `sync-failed-retry-${runId}@example.com`;

    const password =
      'Sync-Failed@123456';

    let app:
      FastifyInstance | undefined;

    let oldJwtSecret:
      string | undefined;

    try {
      oldJwtSecret =
        process.env.JWT_SECRET;

      process.env.JWT_SECRET =
        'sync-failed-retry-secret-2026';

      const passwordHash =
        await bcrypt.hash(
          password,
          12
        );

      await prisma.organization.create({
        data: {
          id:
            organizationId,

          name:
            `Failed Retry Org ${runId}`,
        },
      });

      await prisma.customer.create({
        data: {
          id:
            customerId,

          name:
            'Failed Retry Customer',
        },
      });

      await prisma.user.create({
        data: {
          id:
            adminId,

          name:
            'Failed Retry Admin',

          email,

          passwordHash,

          role:
            Role.ADMIN,

          status:
            UserStatus.ACTIVE,
        },
      });

      await prisma.membership.create({
        data: {
          userId:
            adminId,

          organizationId,

          role:
            Role.ADMIN,
        },
      });

      await prisma.customerOrganization.create({
        data: {
          customerId,

          organizationId,

          status:
            CustomerOrganizationStatus.ACTIVE,
        },
      });

      await prisma.equipment.create({
        data: {
          id:
            equipmentId,

          customerId,

          ownerType:
            EquipmentOwnerType.CUSTOMER,

          type:
            'NOTEBOOK',

          brand:
            'Retry',

          model:
            'Invalid Transition',
        },
      });

      await prisma.serviceOrder.create({
        data: {
          id:
            orderId,

          organizationId,

          customerId,

          equipmentId,

          status:
            ServiceOrderStatus.PRONTO,

          problemDescription:
            'Retry must remain failed',
        },
      });

      app =
        buildApp();

      await app.ready();

      const login =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/auth/login',

          payload: {
            email,

            password,
          },
        });

      assert.equal(
        login.statusCode,
        200
      );

      const token =
        login.json().token;

      const payload = {
        entries: [
          {
            operationId,

            entityType:
              'SERVICE_ORDER',

            entityId:
              orderId,

            operationType:
              'UPDATE',

            payload: {
              customerId,

              equipmentId,

              status:
                ServiceOrderStatus.DIAGNOSTICO,

              problemDescription:
                'Retry must remain failed',
            },

            createdAt:
              new Date()
                .toISOString(),
          },
        ],
      };

      const first =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/sync/push',

          headers: {
            authorization:
              `Bearer ${token}`,
          },

          payload,
        });

      assert.equal(
        first.statusCode,
        200
      );

      assert.equal(
        first.json().results[0].status,
        'FAILED'
      );

      assert.equal(
        await prisma.operationIdempotency.count({
          where: {
            operationId,
          },
        }),
        0
      );

      const retry =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/sync/push',

          headers: {
            authorization:
              `Bearer ${token}`,
          },

          payload,
        });

      assert.equal(
        retry.statusCode,
        200
      );

      assert.equal(
        retry.json().results[0].status,
        'FAILED'
      );

      const order =
        await prisma.serviceOrder.findUniqueOrThrow({
          where: {
            id:
              orderId,
          },
        });

      assert.equal(
        order.status,
        ServiceOrderStatus.PRONTO
      );
    } finally {
      await prisma.operationIdempotency.deleteMany({
        where: {
          operationId,
        },
      });

      await prisma.syncChangeLog.deleteMany({
        where: {
          entityId:
            orderId,
        },
      });

      await prisma.customerEvent.deleteMany({
        where: {
          serviceOrderId:
            orderId,
        },
      });

      await prisma.serviceOrderStatusHistory.deleteMany({
        where: {
          serviceOrderId:
            orderId,
        },
      });

      await prisma.serviceOrder.deleteMany({
        where: {
          id:
            orderId,
        },
      });

      await prisma.equipment.deleteMany({
        where: {
          id:
            equipmentId,
        },
      });

      await prisma.customerOrganization.deleteMany({
        where: {
          customerId,
        },
      });

      await prisma.membership.deleteMany({
        where: {
          userId:
            adminId,
        },
      });

      await prisma.user.deleteMany({
        where: {
          id:
            adminId,
        },
      });

      await prisma.customer.deleteMany({
        where: {
          id:
            customerId,
        },
      });

      await prisma.organization.deleteMany({
        where: {
          id:
            organizationId,
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
 * T054 — CUSTOMER MULTI-ORGANIZATION PUSH
 * ============================================================
 */
test(
  'CUSTOMER Sync Push resolves target Organization and still blocks FIN-F02 approval edge',
  async () => {
    const runId =
      randomUUID();

    const organizationAId =
      randomUUID();

    const organizationBId =
      randomUUID();

    const customerId =
      randomUUID();

    const customerUserId =
      randomUUID();

    const equipmentId =
      randomUUID();

    const orderId =
      randomUUID();

    const operationId =
      randomUUID();

    const email =
      `sync-customer-multiorg-${runId}@example.com`;

    const password =
      'Sync-MultiOrg@123456';

    let app:
      FastifyInstance | undefined;

    let oldJwtSecret:
      string | undefined;

    try {
      oldJwtSecret =
        process.env.JWT_SECRET;

      process.env.JWT_SECRET =
        'sync-customer-multiorg-secret-2026';

      const passwordHash =
        await bcrypt.hash(
          password,
          12
        );

      await prisma.organization.createMany({
        data: [
          {
            id:
              organizationAId,

            name:
              `MultiOrg A ${runId}`,
          },
          {
            id:
              organizationBId,

            name:
              `MultiOrg B ${runId}`,
          },
        ],
      });

      await prisma.customer.create({
        data: {
          id:
            customerId,

          name:
            'MultiOrg Customer',

          email,
        },
      });

      await prisma.user.create({
        data: {
          id:
            customerUserId,

          name:
            'MultiOrg Customer',

          email,

          passwordHash,

          role:
            Role.CUSTOMER,

          status:
            UserStatus.ACTIVE,

          customerId,
        },
      });

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

      await prisma.equipment.create({
        data: {
          id:
            equipmentId,

          customerId,

          ownerType:
            EquipmentOwnerType.CUSTOMER,

          type:
            'CELULAR',

          brand:
            'MultiOrg',

          model:
            'B',
        },
      });

      await prisma.serviceOrder.create({
        data: {
          id:
            orderId,

          organizationId:
            organizationBId,

          customerId,

          equipmentId,

          status:
            ServiceOrderStatus.AGUARDANDO_APROVACAO,

          problemDescription:
            'Order belongs to Organization B',
        },
      });

      app =
        buildApp();

      await app.ready();

      const login =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/auth/login',

          payload: {
            email,

            password,
          },
        });

      assert.equal(
        login.statusCode,
        200
      );

      const token =
        login.json().token;

      const response =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/sync/push',

          headers: {
            authorization:
              `Bearer ${token}`,
          },

          payload: {
            entries: [
              {
                operationId,

                entityType:
                  'SERVICE_ORDER',

                entityId:
                  orderId,

                operationType:
                  'UPDATE',

                payload: {
                  customerId,

                  equipmentId,

                  status:
                    ServiceOrderStatus.EM_EXECUCAO,

                  problemDescription:
                    'Order belongs to Organization B',
                },

                createdAt:
                  new Date()
                    .toISOString(),
              },
            ],
          },
        });

      assert.equal(
        response.statusCode,
        200
      );

      /**
       * FIN-F02 security semantics:
       *
       * This request must get far enough to resolve the ServiceOrder tenant
       * from Organization B, but generic Sync cannot perform the protected
       * CUSTOMER approval edge:
       *
       * AGUARDANDO_APROVACAO -> EM_EXECUCAO
       *
       * Reaching FINANCE_COMMAND_REQUIRED proves the target-resource tenant
       * resolution succeeded instead of failing earlier on Organization
       * ownership.
       */
      assert.equal(
        response.json().results[0].status,
        'FAILED'
      );

      assert.match(
        String(
          response.json().results[0].error
        ),
        /FINANCE_COMMAND_REQUIRED/
      );

      const unchanged =
        await prisma.serviceOrder.findUniqueOrThrow({
          where: {
            id:
              orderId,
          },
        });

      assert.equal(
        unchanged.organizationId,
        organizationBId
      );

      assert.equal(
        unchanged.status,
        ServiceOrderStatus.AGUARDANDO_APROVACAO
      );

      const forbiddenHistory =
        await prisma.serviceOrderStatusHistory.findFirst({
          where: {
            serviceOrderId:
              orderId,

            newStatus:
              ServiceOrderStatus.EM_EXECUCAO,
          },
        });

      assert.equal(
        forbiddenHistory,
        null
      );

      const forbiddenChange =
        await prisma.syncChangeLog.findFirst({
          where: {
            entityType:
              'SERVICE_ORDER',

            entityId:
              orderId,

            operationType:
              OperationType.UPDATE,
          },
        });

      assert.equal(
        forbiddenChange,
        null
      );
    } finally {
      await prisma.operationIdempotency.deleteMany({
        where: {
          operationId,
        },
      });

      await prisma.syncChangeLog.deleteMany({
        where: {
          entityId:
            orderId,
        },
      });

      await prisma.customerEvent.deleteMany({
        where: {
          serviceOrderId:
            orderId,
        },
      });

      await prisma.serviceOrderStatusHistory.deleteMany({
        where: {
          serviceOrderId:
            orderId,
        },
      });

      await prisma.serviceOrder.deleteMany({
        where: {
          id:
            orderId,
        },
      });

      await prisma.equipment.deleteMany({
        where: {
          id:
            equipmentId,
        },
      });

      await prisma.customerOrganization.deleteMany({
        where: {
          customerId,
        },
      });

      await prisma.user.deleteMany({
        where: {
          id:
            customerUserId,
        },
      });

      await prisma.customer.deleteMany({
        where: {
          id:
            customerId,
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
 * T055 — SERVICE ORDER DOMAIN EFFECTS VIA SYNC
 * ============================================================
 */
test(
  'ServiceOrder status transition through Sync preserves History, CRM event and canonical ChangeLog',
  async () => {
    const runId =
      randomUUID();

    const organizationId =
      randomUUID();

    const customerId =
      randomUUID();

    const equipmentId =
      randomUUID();

    const orderId =
      randomUUID();

    const adminId =
      randomUUID();

    const operationId =
      randomUUID();

    const email =
      `sync-domain-effects-${runId}@example.com`;

    const password =
      'Sync-Domain@123456';

    let app:
      FastifyInstance | undefined;

    let oldJwtSecret:
      string | undefined;

    try {
      oldJwtSecret =
        process.env.JWT_SECRET;

      process.env.JWT_SECRET =
        'sync-domain-effects-secret-2026';

      const passwordHash =
        await bcrypt.hash(
          password,
          12
        );

      await prisma.organization.create({
        data: {
          id:
            organizationId,

          name:
            `Domain Effects Org ${runId}`,
        },
      });

      await prisma.customer.create({
        data: {
          id:
            customerId,

          name:
            'Domain Effects Customer',
        },
      });

      await prisma.user.create({
        data: {
          id:
            adminId,

          name:
            'Domain Effects Admin',

          email,

          passwordHash,

          role:
            Role.ADMIN,

          status:
            UserStatus.ACTIVE,
        },
      });

      await prisma.membership.create({
        data: {
          userId:
            adminId,

          organizationId,

          role:
            Role.ADMIN,
        },
      });

      await prisma.customerOrganization.create({
        data: {
          customerId,

          organizationId,

          status:
            CustomerOrganizationStatus.ACTIVE,
        },
      });

      await prisma.equipment.create({
        data: {
          id:
            equipmentId,

          customerId,

          ownerType:
            EquipmentOwnerType.CUSTOMER,

          type:
            'NOTEBOOK',

          brand:
            'Domain',

          model:
            'Effects',
        },
      });

      await prisma.serviceOrder.create({
        data: {
          id:
            orderId,

          organizationId,

          customerId,

          equipmentId,

          status:
            ServiceOrderStatus.PRONTO,

          problemDescription:
            'Must produce domain effects',
        },
      });

      app =
        buildApp();

      await app.ready();

      const login =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/auth/login',

          payload: {
            email,

            password,
          },
        });

      assert.equal(
        login.statusCode,
        200
      );

      const token =
        login.json().token;

      const response =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/sync/push',

          headers: {
            authorization:
              `Bearer ${token}`,
          },

          payload: {
            entries: [
              {
                operationId,

                entityType:
                  'SERVICE_ORDER',

                entityId:
                  orderId,

                operationType:
                  'UPDATE',

                payload: {
                  customerId,

                  equipmentId,

                  status:
                    ServiceOrderStatus.ENTREGUE,

                  problemDescription:
                    'Must produce domain effects',

                  diagnosis:
                    'Finished',

                  solution:
                    'Delivered',

                  totalAmount:
                    150,
                },

                createdAt:
                  new Date()
                    .toISOString(),
              },
            ],
          },
        });

      assert.equal(
        response.statusCode,
        200
      );

      assert.equal(
        response.json().results[0].status,
        'SYNCED'
      );

      assert.equal(
        await prisma.serviceOrderStatusHistory.count({
          where: {
            serviceOrderId:
              orderId,

            previousStatus:
              ServiceOrderStatus.PRONTO,

            newStatus:
              ServiceOrderStatus.ENTREGUE,

            changedById:
              adminId,
          },
        }),
        1
      );

      assert.equal(
        await prisma.customerEvent.count({
          where: {
            serviceOrderId:
              orderId,

            type:
              CustomerEventType.SERVICE_ORDER_COMPLETED,
          },
        }),
        1
      );

      const change =
        await prisma.syncChangeLog.findFirst({
          where: {
            entityType:
              'SERVICE_ORDER',

            entityId:
              orderId,

            operationType:
              OperationType.UPDATE,
          },

          orderBy: {
            id:
              'desc',
          },
        });

      assert.ok(
        change
      );

      const data =
        change.data as
          Record<string, unknown>;

      assert.equal(
        data.status,
        ServiceOrderStatus.ENTREGUE
      );

      assert.equal(
        data.organizationId,
        organizationId
      );

      assert.equal(
        data.customerId,
        customerId
      );

      assert.equal(
        data.equipmentId,
        equipmentId
      );
    } finally {
      await prisma.operationIdempotency.deleteMany({
        where: {
          operationId,
        },
      });

      await prisma.syncChangeLog.deleteMany({
        where: {
          entityId:
            orderId,
        },
      });

      await prisma.customerEvent.deleteMany({
        where: {
          serviceOrderId:
            orderId,
        },
      });

      await prisma.serviceOrderStatusHistory.deleteMany({
        where: {
          serviceOrderId:
            orderId,
        },
      });

      await prisma.serviceOrder.deleteMany({
        where: {
          id:
            orderId,
        },
      });

      await prisma.equipment.deleteMany({
        where: {
          id:
            equipmentId,
        },
      });

      await prisma.customerOrganization.deleteMany({
        where: {
          customerId,
        },
      });

      await prisma.membership.deleteMany({
        where: {
          userId:
            adminId,
        },
      });

      await prisma.user.deleteMany({
        where: {
          id:
            adminId,
        },
      });

      await prisma.customer.deleteMany({
        where: {
          id:
            customerId,
        },
      });

      await prisma.organization.deleteMany({
        where: {
          id:
            organizationId,
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
