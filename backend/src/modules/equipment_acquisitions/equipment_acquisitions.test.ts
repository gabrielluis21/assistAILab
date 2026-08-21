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
  EquipmentAcquisitionStatus,
  EquipmentConsentMethod,
  EquipmentOwnerType,
  EquipmentPurpose,
  Role,
  UserStatus,
} from '@prisma/client';

import {
  buildApp,
} from '../../app.js';

import {
  prisma,
} from '../../core/database/prisma.js';

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

    const equipmentIds =
      Array.from(
        {
          length:
            6,
        },
        () =>
          randomUUID()
      );

    const serviceOrderIds =
      Array.from(
        {
          length:
            6,
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
          },

          payload: {
            equipmentId:
              equipmentIds[
                equipmentIndex
              ],

            serviceOrderId:
              serviceOrderIds[
                equipmentIndex
              ],

            purpose,

            offeredAmount:
              350 +
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
              id:
                customerId,
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
  }
);
