import {
  after,
  before,
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
  AcquisitionSource,
  EquipmentAcquisitionStatus,
  EquipmentConsentMethod,
  EquipmentOwnerType,
  EquipmentPurpose,
  IdempotencyStatus,
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
  computeCanonicalHash,
} from '../../core/idempotency/canonical_json.js';

/**
 * ============================================================
 * C4 — EQUIPMENT ACQUISITION / OWNERSHIP TRANSFER
 * ============================================================
 *
 * T031 → C04.01 + C04.03
 * T032 → C04.02
 * T033 → C04.04 authorize
 * T034 → C04.04 reject
 * T035 → C04.05 + C04.06
 * T036 → C04.07
 */
describe(
  'C4 - Equipment Acquisition & Ownership Transfer',
  {
    concurrency:
      false,
  },
  () => {
    let app:
      FastifyInstance;

    let oldJwtSecret:
      string | undefined;

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

    const customerId =
      randomUUID();

    const customerUserId =
      randomUUID();

    const otherCustomerId =
      randomUUID();

    const otherCustomerUserId =
      randomUUID();

    const adminPassword =
      'C4-Admin@123456';

    const customerPassword =
      'C4-Customer@123456';

    const adminAEmail =
      `c4-admin-a-${runId}@assistailab.test`;

    const adminBEmail =
      `c4-admin-b-${runId}@assistailab.test`;

    const customerEmail =
      `c4-customer-${runId}@assistailab.test`;

    const otherCustomerEmail =
      `c4-other-customer-${runId}@assistailab.test`;

    const equipmentIds =
      Array.from(
        {
          length:
            18,
        },
        () =>
          randomUUID()
      );

    const serviceOrderIds =
      Array.from(
        {
          length:
            18,
        },
        () =>
          randomUUID()
      );

    const createdAcquisitionIds:
      string[] =
      [];

    let adminAToken:
      string;

    let adminBToken:
      string;

    let customerToken:
      string;

    let otherCustomerToken:
      string;

    async function login(
      email:
        string,
      password:
        string
    ) {
      return app.inject({
        method:
          'POST',

        url:
          '/api/v1/auth/login',

        payload: {
          email,
          password,
        },
      });
    }

    async function createProposal(
      equipmentIndex:
        number,
      purpose:
        EquipmentPurpose
    ) {
      const response =
        await app.inject({
          method:
            'POST',

          url:
            '/api/v1/equipment-acquisitions',

          headers: {
            authorization:
              `Bearer ${adminAToken}`,
            'x-operation-id':
              randomUUID(),
          },

          payload: {
            source:
              AcquisitionSource.SERVICE_ORDER,

            equipmentId:
              equipmentIds[
                equipmentIndex
              ],

            serviceOrderId:
              serviceOrderIds[
                equipmentIndex
              ],

            purpose,

            offeredAmountMinor:
              35000 +
              equipmentIndex,

            notes:
              `C4 proposal ${equipmentIndex}`,
          },
        });

      assert.equal(
        response.statusCode,
        201
      );

      const body =
        response.json();

      createdAcquisitionIds
        .push(
          body
            .acquisition
            .id
        );

      return body
        .acquisition;
    }

    before(
      async () => {
        oldJwtSecret =
          process.env.JWT_SECRET;

        process.env.JWT_SECRET =
          'c4-integration-test-secret-2026';

        const adminPasswordHash =
          await bcrypt.hash(
            adminPassword,
            12
          );

        const customerPasswordHash =
          await bcrypt.hash(
            customerPassword,
            12
          );

        /**
         * Organizations.
         */
        await prisma
          .organization
          .createMany({
            data: [
              {
                id:
                  organizationAId,

                name:
                  `C4 Organization A ${runId}`,
              },

              {
                id:
                  organizationBId,

                name:
                  `C4 Organization B ${runId}`,
              },
            ],
          });

        /**
         * Professionals.
         */
        await prisma
          .user
          .createMany({
            data: [
              {
                id:
                  adminAId,

                name:
                  'C4 Admin A',

                email:
                  adminAEmail,

                passwordHash:
                  adminPasswordHash,

                role:
                  Role.ADMIN,

                status:
                  UserStatus.ACTIVE,
              },

              {
                id:
                  adminBId,

                name:
                  'C4 Admin B',

                email:
                  adminBEmail,

                passwordHash:
                  adminPasswordHash,

                role:
                  Role.ADMIN,

                status:
                  UserStatus.ACTIVE,
              },
            ],
          });

        await prisma
          .membership
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
            ],
          });

        /**
         * Global Customer + account.
         */
        await prisma
          .customer
          .create({
            data: {
              id:
                customerId,

              name:
                'C4 Customer',

              email:
                customerEmail,
            },
          });

        await prisma.customer.create({
          data: {
            id: otherCustomerId,
            name: 'C4 Other Customer',
            email: otherCustomerEmail,
          },
        });

        await prisma
          .user
          .create({
            data: {
              id:
                customerUserId,

              name:
                'C4 Customer',

              email:
                customerEmail,

              passwordHash:
                customerPasswordHash,

              role:
                Role.CUSTOMER,

              status:
                UserStatus.ACTIVE,

              customerId,
            },
          });

        await prisma.user.create({
          data: {
            id: otherCustomerUserId,
            name: 'C4 Other Customer',
            email: otherCustomerEmail,
            passwordHash: customerPasswordHash,
            role: Role.CUSTOMER,
            status: UserStatus.ACTIVE,
            customerId: otherCustomerId,
          },
        });

        await prisma
          .customerOrganization
          .create({
            data: {
              customerId,

              organizationId:
                organizationAId,

              status:
                'ACTIVE',
            },
          });

        /**
         * Seis Equipments CUSTOMER.
         *
         * Cada um já apareceu em uma OS da A,
         * portanto a Organization pode conhecê-lo
         * e apresentar proposta.
         */
        for (
          let index =
            0;
          index <
          equipmentIds.length;
          index +=
            1
        ) {
          await prisma
            .equipment
            .create({
              data: {
                id:
                  equipmentIds[
                    index
                  ],

                customerId,

                organizationId:
                  null,

                ownerType:
                  EquipmentOwnerType
                    .CUSTOMER,

                organizationPurpose:
                  null,

                type:
                  index %
                    2 ===
                  0
                    ? 'NOTEBOOK'
                    : 'CELULAR',

                brand:
                  'C4 Brand',

                model:
                  `C4 Equipment ${index}`,
              },
            });

          await prisma
            .serviceOrder
            .create({
              data: {
                id:
                  serviceOrderIds[
                    index
                  ],

                organizationId:
                  organizationAId,

                customerId,

                equipmentId:
                  equipmentIds[
                    index
                  ],

                problemDescription:
                  `C4 acquisition source OS ${index}`,
              },
            });
        }

        app =
          buildApp();

        await app.ready();

        /**
         * Tokens.
         */
        const adminALogin =
          await login(
            adminAEmail,
            adminPassword
          );

        const adminBLogin =
          await login(
            adminBEmail,
            adminPassword
          );

        const customerLogin =
          await login(
            customerEmail,
            customerPassword
          );

        const otherCustomerLogin = await login(
          otherCustomerEmail,
          customerPassword
        );

        assert.equal(
          adminALogin.statusCode,
          200
        );

        assert.equal(
          adminBLogin.statusCode,
          200
        );

        assert.equal(
          customerLogin.statusCode,
          200
        );

        assert.equal(otherCustomerLogin.statusCode, 200);

        adminAToken =
          adminALogin
            .json()
            .token;

        adminBToken =
          adminBLogin
            .json()
            .token;

        customerToken =
          customerLogin
            .json()
            .token;

        otherCustomerToken = otherCustomerLogin.json().token;
      }
    );

    after(
      async () => {
        await prisma
          .equipmentAcquisition
          .deleteMany({
            where: {
              OR: [
                {
                  id: {
                    in:
                      createdAcquisitionIds,
                  },
                },

                {
                  organizationId:
                    organizationAId,
                },
              ],
            },
          });

        await prisma.operationIdempotency.deleteMany({
          where: {
            organizationId: {
              in: [organizationAId, organizationBId],
            },
          },
        });

        await prisma
          .serviceOrder
          .deleteMany({
            where: {
              id: {
                in:
                  serviceOrderIds,
              },
            },
          });

        /**
         * Equipments continuam referenciados pelas OS
         * até a remoção acima.
         */
        await prisma
          .equipment
          .deleteMany({
            where: {
              id: {
                in:
                  equipmentIds,
              },
            },
          });

        await prisma
          .membership
          .deleteMany({
            where: {
              userId: {
                in: [
                  adminAId,
                  adminBId,
                ],
              },
            },
          });

        await prisma
          .user
          .deleteMany({
            where: {
              id: {
                in: [
                  adminAId,
                  adminBId,
                  customerUserId,
                  otherCustomerUserId,
                ],
              },
            },
          });

        await prisma
          .customerOrganization
          .deleteMany({
            where: {
              customerId,
            },
          });

        await prisma
          .customer
          .deleteMany({
            where: {
              id: {
                in: [customerId, otherCustomerId],
              },
            },
          });

        await prisma
          .organization
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

        if (
          oldJwtSecret
        ) {
          process.env.JWT_SECRET =
            oldJwtSecret;
        } else {
          delete process
            .env
            .JWT_SECRET;
        }
      }
    );

    /**
     * ========================================================
     * T031 / C04.01 + C04.03
     * ========================================================
     */
    test(
      'Organization creates a RESALE proposal without transferring ownership and cannot complete it while PENDING',
      async () => {
        const acquisition =
          await createProposal(
            0,
            EquipmentPurpose
              .RESALE
          );

        assert.equal(
          acquisition.status,
          EquipmentAcquisitionStatus
            .PENDING
        );

        assert.equal(
          acquisition.purpose,
          EquipmentPurpose
            .RESALE
        );

        assert.equal(
          acquisition
            .serviceOrder
            .id,
          serviceOrderIds[
            0
          ]
        );

        const equipmentBefore =
          await prisma
            .equipment
            .findUniqueOrThrow({
              where: {
                id:
                  equipmentIds[
                    0
                  ],
              },
            });

        assert.equal(
          equipmentBefore
            .ownerType,
          EquipmentOwnerType
            .CUSTOMER
        );

        assert.equal(
          equipmentBefore
            .customerId,
          customerId
        );

        assert.equal(
          equipmentBefore
            .organizationId,
          null
        );

        /**
         * PENDING não pode transferir.
         */
        const completeResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${acquisition.id}/complete`,

            headers: {
              authorization:
                `Bearer ${adminAToken}`,
              'x-operation-id': randomUUID(),
            },
          });

        assert.equal(
          completeResponse.statusCode,
          409
        );

        const equipmentAfter =
          await prisma
            .equipment
            .findUniqueOrThrow({
              where: {
                id:
                  equipmentIds[
                    0
                  ],
              },
            });

        assert.equal(
          equipmentAfter
            .ownerType,
          EquipmentOwnerType
            .CUSTOMER
        );
      }
    );

    /**
     * ========================================================
     * T032 / C04.02
     * ========================================================
     */
    test(
      'Acquisition proposal distinguishes PARTS_DONOR from RESALE',
      async () => {
        const acquisition =
          await createProposal(
            1,
            EquipmentPurpose
              .PARTS_DONOR
          );

        assert.equal(
          acquisition.purpose,
          EquipmentPurpose
            .PARTS_DONOR
        );

        const persisted =
          await prisma
            .equipmentAcquisition
            .findUniqueOrThrow({
              where: {
                id:
                  acquisition.id,
              },
            });

        assert.equal(
          persisted.purpose,
          EquipmentPurpose
            .PARTS_DONOR
        );
      }
    );

    /**
     * ========================================================
     * T033 / C04.04
     * ========================================================
     */
    test(
      'Customer authorizes the presented acquisition and backend records immutable consent evidence',
      async () => {
        const proposal =
          await createProposal(
            2,
            EquipmentPurpose
              .RESALE
          );

        const response =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/authorize`,

            headers: {
              authorization:
                `Bearer ${customerToken}`,
              'x-operation-id': randomUUID(),
            },

            payload: {
              consentMethod:
                EquipmentConsentMethod
                  .CUSTOMER_APP,
            },
          });

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.equal(
          body
            .acquisition
            .status,
          EquipmentAcquisitionStatus
            .AUTHORIZED
        );

        assert.equal(
          body
            .acquisition
            .purpose,
          EquipmentPurpose
            .RESALE
        );

        const persisted =
          await prisma
            .equipmentAcquisition
            .findUniqueOrThrow({
              where: {
                id:
                  proposal.id,
              },
            });

        assert.equal(
          persisted.status,
          EquipmentAcquisitionStatus
            .AUTHORIZED
        );

        assert.equal(
          persisted
            .consentMethod,
          EquipmentConsentMethod
            .CUSTOMER_APP
        );

        assert.ok(
          persisted
            .authorizedAt
        );

        assert.ok(
          persisted
            .consentSnapshot
        );

        assert.equal(
          persisted
            .consentHash
            ?.length,
          64
        );

        /**
         * AUTHORIZED ainda NÃO transfere.
         */
        const equipment =
          await prisma
            .equipment
            .findUniqueOrThrow({
              where: {
                id:
                  equipmentIds[
                    2
                  ],
              },
            });

        assert.equal(
          equipment.ownerType,
          EquipmentOwnerType
            .CUSTOMER
        );

        assert.equal(
          equipment.customerId,
          customerId
        );
      }
    );

    /**
     * ========================================================
     * T034 / C04.04
     * ========================================================
     */
    test(
      'Customer can reject a pending acquisition and rejected proposal never transfers ownership',
      async () => {
        const proposal =
          await createProposal(
            3,
            EquipmentPurpose
              .PARTS_DONOR
          );

        const rejectResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/reject`,

            headers: {
              authorization:
                `Bearer ${customerToken}`,
              'x-operation-id': randomUUID(),
            },
          });

        assert.equal(
          rejectResponse.statusCode,
          200
        );

        assert.equal(
          rejectResponse
            .json()
            .acquisition
            .status,
          EquipmentAcquisitionStatus
            .REJECTED
        );

        const rejectAudit = await prisma.customerEvent.findFirst({
          where: {
            customerId,
            organizationId: organizationAId,
            title: 'Equipment acquisition REJECT',
            metadata: { path: '$.acquisitionId', equals: proposal.id },
          },
        });
        assert.ok(rejectAudit);
        assert.equal((rejectAudit.metadata as any).actorUserId, customerUserId);

        /**
         * Organization não pode completar
         * uma proposta rejeitada.
         */
        const completeResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/complete`,

            headers: {
              authorization:
                `Bearer ${adminAToken}`,
              'x-operation-id': randomUUID(),
            },
          });

        assert.equal(
          completeResponse.statusCode,
          409
        );

        const equipment =
          await prisma
            .equipment
            .findUniqueOrThrow({
              where: {
                id:
                  equipmentIds[
                    3
                  ],
              },
            });

        assert.equal(
          equipment.ownerType,
          EquipmentOwnerType
            .CUSTOMER
        );
      }
    );

    /**
     * ========================================================
     * T035 / C04.05 + C04.06
     * ========================================================
     */
    test(
      'Completing an AUTHORIZED acquisition transfers Equipment ownership to the Organization and grants direct access',
      async () => {
        const proposal =
          await createProposal(
            4,
            EquipmentPurpose
              .RESALE
          );

        const authorizeResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/authorize`,

            headers: {
              authorization:
                `Bearer ${customerToken}`,
              'x-operation-id': randomUUID(),
            },

            payload: {
              consentMethod:
                EquipmentConsentMethod
                  .QR_CODE,
            },
          });

        assert.equal(
          authorizeResponse.statusCode,
          200
        );

        const completeResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/complete`,

            headers: {
              authorization:
                `Bearer ${adminAToken}`,
              'x-operation-id': randomUUID(),
            },
          });

        assert.equal(
          completeResponse.statusCode,
          200
        );

        assert.equal(
          completeResponse
            .json()
            .acquisition
            .status,
          EquipmentAcquisitionStatus
            .COMPLETED
        );

        const equipment =
          await prisma
            .equipment
            .findUniqueOrThrow({
              where: {
                id:
                  equipmentIds[
                    4
                  ],
              },
            });

        assert.equal(
          equipment.ownerType,
          EquipmentOwnerType
            .ORGANIZATION
        );

        assert.equal(
          equipment.customerId,
          null
        );

        assert.equal(
          equipment
            .organizationId,
          organizationAId
        );

        assert.equal(
          equipment
            .organizationPurpose,
          EquipmentPurpose
            .RESALE
        );

        /**
         * A passa a ter acesso direto,
         * sem depender de Customer ownership.
         */
        const equipmentResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment/${equipmentIds[4]}`,

            headers: {
              authorization:
                `Bearer ${adminAToken}`,
            },
          });

        assert.equal(
          equipmentResponse.statusCode,
          200
        );

        assert.equal(
          equipmentResponse
            .json()
            .ownerType,
          EquipmentOwnerType
            .ORGANIZATION
        );
      }
    );

    /**
     * ========================================================
     * T036 / C04.07
     * ========================================================
     */
    test(
      'Another Organization cannot access the acquisition or the Equipment acquired by Organization A',
      async () => {
        const proposal =
          await createProposal(
            5,
            EquipmentPurpose
              .PARTS_DONOR
          );

        const authorizeResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/authorize`,

            headers: {
              authorization:
                `Bearer ${customerToken}`,
              'x-operation-id': randomUUID(),
            },

            payload: {
              consentMethod:
                EquipmentConsentMethod
                  .CUSTOMER_APP,
            },
          });

        assert.equal(
          authorizeResponse.statusCode,
          200
        );

        const completeResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}/complete`,

            headers: {
              authorization:
                `Bearer ${adminAToken}`,
              'x-operation-id': randomUUID(),
            },
          });

        assert.equal(
          completeResponse.statusCode,
          200
        );

        /**
         * B não vê a aquisição.
         */
        const acquisitionFromB =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment-acquisitions/${proposal.id}`,

            headers: {
              authorization:
                `Bearer ${adminBToken}`,
            },
          });

        assert.equal(
          acquisitionFromB.statusCode,
          404
        );

        /**
         * B também não vê o Equipment
         * adquirido pela A.
         */
        const equipmentFromB =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment/${equipmentIds[5]}`,

            headers: {
              authorization:
                `Bearer ${adminBToken}`,
            },
          });

        assert.equal(
          equipmentFromB.statusCode,
          404
        );
      }
    );

    test(
      'P08-B validates explicit source, exact money, canonical idempotency and business correlation',
      async () => {
        const operationId = randomUUID();
        const clientPreAcquisitionId = randomUUID();
        const payload = {
          source: AcquisitionSource.DIRECT_OFFER,
          equipmentId: equipmentIds[9],
          purpose: EquipmentPurpose.RESALE,
          offeredAmountMinor: 125001,
          notes: 'Direct offer intent',
          clientPreAcquisitionId,
        };
        const headers = {
          authorization: `Bearer ${adminAToken}`,
          'x-operation-id': operationId,
        };

        const missingServiceOrder = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: {
            source: AcquisitionSource.SERVICE_ORDER,
            equipmentId: equipmentIds[17],
            purpose: EquipmentPurpose.RESALE,
          },
        });
        assert.equal(missingServiceOrder.statusCode, 400);

        const serviceEndpointWithDirectSource = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: {
            source: AcquisitionSource.DIRECT_OFFER,
            equipmentId: equipmentIds[17],
            serviceOrderId: serviceOrderIds[17],
            purpose: EquipmentPurpose.RESALE,
          },
        });
        assert.equal(serviceEndpointWithDirectSource.statusCode, 400);

        const directWithServiceOrder = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: { ...payload, serviceOrderId: serviceOrderIds[9] },
        });
        assert.equal(directWithServiceOrder.statusCode, 400);

        const missingOperationId = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}` },
          payload,
        });
        assert.equal(missingOperationId.statusCode, 400);

        const created = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers,
          payload,
        });
        assert.equal(created.statusCode, 201);
        const createdAcquisition = created.json().acquisition;
        createdAcquisitionIds.push(createdAcquisition.id);
        assert.equal(createdAcquisition.source, AcquisitionSource.DIRECT_OFFER);
        assert.equal(createdAcquisition.serviceOrderId, null);
        assert.equal(createdAcquisition.offeredAmountMinor, 125001);
        assert.equal('offeredAmount' in createdAcquisition, false);
        assert.equal('activeEquipmentGuard' in createdAcquisition, false);

        const persisted = await prisma.equipmentAcquisition.findUniqueOrThrow({
          where: { id: createdAcquisition.id },
        });
        assert.equal(persisted.offeredAmount?.toFixed(2), '1250.01');
        assert.equal(persisted.customerId, customerId);
        assert.equal(persisted.createdByUserId, adminAId);
        assert.equal(persisted.activeEquipmentGuard, equipmentIds[9]);

        const replay = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers,
          payload,
        });
        assert.equal(replay.statusCode, 201);
        assert.equal(replay.json().acquisition.id, createdAcquisition.id);

        const keyReuse = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers,
          payload: { ...payload, notes: 'Different request' },
        });
        assert.equal(keyReuse.statusCode, 409);

        const businessRetry = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload,
        });
        assert.equal(businessRetry.statusCode, 200);
        assert.equal(businessRetry.json().acquisition.id, createdAcquisition.id);

        await prisma.equipment.update({
          where: { id: equipmentIds[9] },
          data: { customerId: otherCustomerId },
        });
        try {
          const incompatibleCustomerIntent = await app.inject({
            method: 'POST',
            url: '/api/v1/equipment-acquisitions/direct-offer',
            headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
            payload,
          });
          assert.equal(incompatibleCustomerIntent.statusCode, 409);
          assert.equal(
            incompatibleCustomerIntent.json().error,
            'CLIENT_PRE_ACQUISITION_INTENT_CONFLICT'
          );
        } finally {
          await prisma.equipment.update({
            where: { id: equipmentIds[9] },
            data: { customerId },
          });
        }

        const incompatibleIntent = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: { ...payload, equipmentId: equipmentIds[10] },
        });
        assert.equal(incompatibleIntent.statusCode, 409);

        const createAudit = await prisma.customerEvent.findFirst({
          where: {
            customerId,
            organizationId: organizationAId,
            title: 'Equipment acquisition CREATE',
            metadata: { path: '$.acquisitionId', equals: createdAcquisition.id },
          },
        });
        assert.ok(createAudit);
        assert.equal((createAudit.metadata as any).actorUserId, adminAId);
      }
    );

    test(
      'P08-B enforces one active acquisition across SO x SO, SO x DIRECT and DIRECT x DIRECT',
      async () => {
        const staffHeaders = () => ({
          authorization: `Bearer ${adminAToken}`,
          'x-operation-id': randomUUID(),
        });
        const servicePayload = (index: number) => ({
          source: AcquisitionSource.SERVICE_ORDER,
          equipmentId: equipmentIds[index],
          serviceOrderId: serviceOrderIds[index],
          purpose: EquipmentPurpose.RESALE,
        });
        const directPayload = (index: number) => ({
          source: AcquisitionSource.DIRECT_OFFER,
          equipmentId: equipmentIds[index],
          purpose: EquipmentPurpose.RESALE,
        });
        const cases = [
          {
            index: 6,
            calls: () => Promise.all([
              app.inject({ method: 'POST', url: '/api/v1/equipment-acquisitions', headers: staffHeaders(), payload: servicePayload(6) }),
              app.inject({ method: 'POST', url: '/api/v1/equipment-acquisitions', headers: staffHeaders(), payload: servicePayload(6) }),
            ]),
          },
          {
            index: 7,
            calls: () => Promise.all([
              app.inject({ method: 'POST', url: '/api/v1/equipment-acquisitions', headers: staffHeaders(), payload: servicePayload(7) }),
              app.inject({ method: 'POST', url: '/api/v1/equipment-acquisitions/direct-offer', headers: staffHeaders(), payload: directPayload(7) }),
            ]),
          },
          {
            index: 8,
            calls: () => Promise.all([
              app.inject({ method: 'POST', url: '/api/v1/equipment-acquisitions/direct-offer', headers: staffHeaders(), payload: directPayload(8) }),
              app.inject({ method: 'POST', url: '/api/v1/equipment-acquisitions/direct-offer', headers: staffHeaders(), payload: directPayload(8) }),
            ]),
          },
        ];

        for (const concurrencyCase of cases) {
          const responses = await concurrencyCase.calls();
          assert.deepEqual(responses.map(response => response.statusCode).sort(), [201, 409]);
          const activeCount = await prisma.equipmentAcquisition.count({
            where: {
              equipmentId: equipmentIds[concurrencyCase.index],
              status: { in: [EquipmentAcquisitionStatus.PENDING, EquipmentAcquisitionStatus.AUTHORIZED] },
            },
          });
          assert.equal(activeCount, 1);
        }
      }
    );

    test(
      'P08-B scopes customer authorization and limits assisted consent to pending direct offers',
      async () => {
        const direct = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: {
            source: AcquisitionSource.DIRECT_OFFER,
            equipmentId: equipmentIds[10],
            purpose: EquipmentPurpose.PARTS_DONOR,
          },
        });
        assert.equal(direct.statusCode, 201);
        const directId = direct.json().acquisition.id;

        const wrongCustomer = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${directId}/authorize`,
          headers: { authorization: `Bearer ${otherCustomerToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.CUSTOMER_APP },
        });
        assert.equal(wrongCustomer.statusCode, 404);

        const assisted = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${directId}/authorize-in-person`,
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.IN_PERSON_ASSISTED },
        });
        assert.equal(assisted.statusCode, 200);
        assert.equal(assisted.json().acquisition.status, EquipmentAcquisitionStatus.AUTHORIZED);

        const persistedDirect = await prisma.equipmentAcquisition.findUniqueOrThrow({ where: { id: directId } });
        assert.equal(persistedDirect.authorizedByUserId, adminAId);
        assert.equal(persistedDirect.consentMethod, EquipmentConsentMethod.IN_PERSON_ASSISTED);

        const serviceOrderProposal = await createProposal(11, EquipmentPurpose.RESALE);
        const invalidAssisted = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${serviceOrderProposal.id}/authorize-in-person`,
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.IN_PERSON_ASSISTED },
        });
        assert.equal(invalidAssisted.statusCode, 409);

        const customerProposal = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: {
            source: AcquisitionSource.DIRECT_OFFER,
            equipmentId: equipmentIds[12],
            purpose: EquipmentPurpose.RESALE,
          },
        });
        const customerProposalId = customerProposal.json().acquisition.id;
        const forbiddenMethod = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${customerProposalId}/authorize`,
          headers: { authorization: `Bearer ${customerToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.IN_PERSON_ASSISTED },
        });
        assert.equal(forbiddenMethod.statusCode, 400);

        const correctCustomer = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${customerProposalId}/authorize`,
          headers: { authorization: `Bearer ${customerToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.DIGITAL_SIGNATURE },
        });
        assert.equal(correctCustomer.statusCode, 200);
        assert.equal(correctCustomer.json().acquisition.authorizedByUserId, customerUserId);
      }
    );

    test(
      'P08-B completes ownership atomically once under race and records reconstructable audit',
      async () => {
        const clientPreAcquisitionId = randomUUID();
        const directPayload = {
          source: AcquisitionSource.DIRECT_OFFER,
          equipmentId: equipmentIds[13],
          purpose: EquipmentPurpose.RESALE,
          clientPreAcquisitionId,
        };
        const proposal = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: directPayload,
        });
        const acquisitionId = proposal.json().acquisition.id;
        const authorize = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${acquisitionId}/authorize`,
          headers: { authorization: `Bearer ${customerToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.SIGNED_DOCUMENT },
        });
        assert.equal(authorize.statusCode, 200);

        const operationIds = [randomUUID(), randomUUID()];
        const completions = await Promise.all(operationIds.map(currentOperationId => app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${acquisitionId}/complete`,
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': currentOperationId },
        })));
        assert.deepEqual(completions.map(response => response.statusCode).sort(), [200, 409]);

        const successIndex = completions.findIndex(response => response.statusCode === 200);
        const replay = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${acquisitionId}/complete`,
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': operationIds[successIndex] },
        });
        assert.equal(replay.statusCode, 200);

        const [persistedAcquisition, equipment, auditEvents] = await Promise.all([
          prisma.equipmentAcquisition.findUniqueOrThrow({ where: { id: acquisitionId } }),
          prisma.equipment.findUniqueOrThrow({ where: { id: equipmentIds[13] } }),
          prisma.customerEvent.findMany({
            where: {
              organizationId: organizationAId,
              title: {
                in: [
                  'Equipment acquisition CREATE',
                  'Equipment acquisition AUTHORIZE',
                  'Equipment acquisition COMPLETE',
                ],
              },
              metadata: { path: '$.acquisitionId', equals: acquisitionId },
            },
          }),
        ]);
        assert.equal(persistedAcquisition.status, EquipmentAcquisitionStatus.COMPLETED);
        assert.equal(persistedAcquisition.completedByUserId, adminAId);
        assert.equal(persistedAcquisition.activeEquipmentGuard, null);
        assert.equal(equipment.ownerType, EquipmentOwnerType.ORGANIZATION);
        assert.equal(equipment.organizationId, organizationAId);
        assert.equal(equipment.customerId, null);
        assert.deepEqual(
          auditEvents.map(event => (event.metadata as any).action).sort(),
          ['AUTHORIZE', 'COMPLETE', 'CREATE']
        );
        const completeAudit = auditEvents.find(
          event => (event.metadata as any).action === 'COMPLETE'
        );
        assert.equal((completeAudit?.metadata as any).actorUserId, adminAId);

        const businessRetryAfterCompletion = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': randomUUID() },
          payload: directPayload,
        });
        assert.equal(businessRetryAfterCompletion.statusCode, 200);
        assert.equal(businessRetryAfterCompletion.json().acquisition.id, acquisitionId);

        const terminalTransition = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${acquisitionId}/authorize`,
          headers: { authorization: `Bearer ${customerToken}`, 'x-operation-id': randomUUID() },
          payload: { consentMethod: EquipmentConsentMethod.CUSTOMER_APP },
        });
        assert.equal(terminalTransition.statusCode, 409);

        const crossTenantComplete = await app.inject({
          method: 'POST',
          url: `/api/v1/equipment-acquisitions/${acquisitionId}/complete`,
          headers: { authorization: `Bearer ${adminBToken}`, 'x-operation-id': randomUUID() },
        });
        assert.equal(crossTenantComplete.statusCode, 404);
      }
    );

    test(
      'P08-B reports canonical IN_PROGRESS for an unexpired operation reservation',
      async () => {
        const operationId = randomUUID();
        const payload = {
          source: AcquisitionSource.DIRECT_OFFER,
          equipmentId: equipmentIds[14],
          purpose: EquipmentPurpose.RESALE,
        };
        await prisma.operationIdempotency.create({
          data: {
            operationId,
            userId: adminAId,
            organizationId: organizationAId,
            command: 'P08B_CREATE_DIRECT_OFFER',
            endpoint: '/api/v1/equipment-acquisitions/direct-offer',
            requestHash: computeCanonicalHash({
              equipmentId: equipmentIds[14],
              source: AcquisitionSource.DIRECT_OFFER,
              serviceOrderId: null,
              purpose: EquipmentPurpose.RESALE,
              offeredAmountMinor: null,
              notes: null,
              clientPreAcquisitionId: null,
            }),
            status: IdempotencyStatus.PROCESSING,
            processingExpiresAt: new Date(Date.now() + 60_000),
            leaseToken: randomUUID(),
          },
        });

        const response = await app.inject({
          method: 'POST',
          url: '/api/v1/equipment-acquisitions/direct-offer',
          headers: { authorization: `Bearer ${adminAToken}`, 'x-operation-id': operationId },
          payload,
        });
        assert.equal(response.statusCode, 409);
        assert.equal(response.json().error, 'IDEMPOTENCY_IN_PROGRESS');
      }
    );
  }
);
