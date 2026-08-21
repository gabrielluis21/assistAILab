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
  AccessGrantStatus,
  AccessGrantType,
  CustomerOrganizationStatus,
  EquipmentOwnerType,
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
  registerSchema,
} from './auth.schema.js';

/**
 * ============================================================
 * AUTH SECURITY
 * ============================================================
 *
 * T001–T004
 *
 * Mantém a cobertura existente de:
 *
 * C01.01
 * C01.02
 * C03.01
 * C03.02
 * C03.03
 */
describe(
  'Auth Security & Privilege Escalation Hardening',
  {
    concurrency: false,
  },
  () => {
    test(
      'Startup fails when JWT_SECRET is missing',
      () => {
        const oldSecret =
          process.env.JWT_SECRET;

        delete process.env.JWT_SECRET;

        assert.throws(
          () => {
            buildApp();
          },
          /JWT_SECRET environment variable is missing/
        );

        if (oldSecret) {
          process.env.JWT_SECRET =
            oldSecret;
        } else {
          process.env.JWT_SECRET =
            'test-jwt-secret-key-12345';
        }
      }
    );

    test(
      'Public registration rejects role injection',
      () => {
        const invalidPayload = {
          name:
            'Hacker User',

          email:
            'hacker@example.com',

          password:
            'securepassword123',

          organizationId:
            '550e8400-e29b-41d4-a716-446655440000',

          role:
            'ADMIN',
        };

        const parseResult =
          registerSchema.safeParse(
            invalidPayload
          );

        assert.equal(
          parseResult.success,
          true
        );

        if (
          parseResult.success
        ) {
          assert.equal(
            'role' in
            parseResult.data,
            false
          );

          assert.equal(
            'organizationId' in
            parseResult.data,
            false
          );
        }
      }
    );

    test(
      'Public registration requires a password',
      () => {
        const invalidPayload = {
          name:
            'Test User',

          email:
            'test@example.com',

          organizationId:
            '550e8400-e29b-41d4-a716-446655440000',
        };

        const parseResult =
          registerSchema.safeParse(
            invalidPayload
          );

        assert.equal(
          parseResult.success,
          false
        );
      }
    );

    test(
      'Public registration accepts valid customer data',
      () => {
        const validPayload = {
          name:
            'Valid Customer',

          email:
            'customer@example.com',

          password:
            'securepassword123',

          phone:
            '16999999999',

          organizationId:
            '550e8400-e29b-41d4-a716-446655440000',
        };

        const parseResult =
          registerSchema.safeParse(
            validPayload
          );

        assert.equal(
          parseResult.success,
          true
        );

        if (
          parseResult.success
        ) {
          assert.equal(
            'organizationId' in
            parseResult.data,
            false
          );
        }
      }
    );
  }
);

/**
 * ============================================================
 * C1 — ORGANIZATION / AUTHENTICATION / TENANT ISOLATION
 * ============================================================
 *
 * T013–T019
 */
describe(
  'C1 - Organization Authentication & Tenant Isolation',
  {
    concurrency: false,
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

    const userWithoutMembershipId =
      randomUUID();

    const customerBId =
      randomUUID();

    const equipmentBId =
      randomUUID();

    const serviceOrderBId =
      randomUUID();

    const adminAEmail =
      `c1-admin-a-${runId}@assistailab.test`;

    const adminBEmail =
      `c1-admin-b-${runId}@assistailab.test`;

    const userWithoutMembershipEmail =
      `c1-no-membership-${runId}@assistailab.test`;

    const password =
      'C1-Test@123456';

    async function login(
      email: string,
      userPassword = password
    ) {
      return app.inject({
        method:
          'POST',

        url:
          '/api/v1/auth/login',

        payload: {
          email,

          password:
            userPassword,
        },
      });
    }

    before(
      async () => {
        oldJwtSecret =
          process.env.JWT_SECRET;

        process.env.JWT_SECRET =
          'c1-integration-test-secret-2026';

        const passwordHash =
          await bcrypt.hash(
            password,
            12
          );

        await prisma.organization.create({
          data: {
            id:
              organizationAId,

            name:
              `C1 Organization A ${runId}`,
          },
        });

        await prisma.organization.create({
          data: {
            id:
              organizationBId,

            name:
              `C1 Organization B ${runId}`,
          },
        });

        await prisma.user.create({
          data: {
            id:
              adminAId,

            name:
              'C1 Admin A',

            email:
              adminAEmail,

            passwordHash,

            role:
              Role.ADMIN,

            status:
              UserStatus.ACTIVE,
          },
        });

        await prisma.user.create({
          data: {
            id:
              adminBId,

            name:
              'C1 Admin B',

            email:
              adminBEmail,

            passwordHash,

            role:
              Role.ADMIN,

            status:
              UserStatus.ACTIVE,
          },
        });

        await prisma.user.create({
          data: {
            id:
              userWithoutMembershipId,

            name:
              'C1 User Without Membership',

            email:
              userWithoutMembershipEmail,

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
              adminAId,

            organizationId:
              organizationAId,

            role:
              Role.ADMIN,
          },
        });

        await prisma.membership.create({
          data: {
            userId:
              adminBId,

            organizationId:
              organizationBId,

            role:
              Role.ADMIN,
          },
        });

        await prisma.customer.create({
          data: {
            id:
              customerBId,

            name:
              'C1 Customer B',

            email:
              `c1-customer-${runId}@assistailab.test`,
          },
        });

        await prisma.customerOrganization.create({
          data: {
            customerId:
              customerBId,

            organizationId:
              organizationBId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        await prisma.equipment.create({
          data: {
            id:
              equipmentBId,

            customerId:
              customerBId,

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
              'C1 Integration Notebook',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id:
              serviceOrderBId,

            organizationId:
              organizationBId,

            customerId:
              customerBId,

            equipmentId:
              equipmentBId,

            problemDescription:
              'C1 multi-tenant isolation test',
          },
        });

        app =
          buildApp();

        await app.ready();
      }
    );

    after(
      async () => {
        await prisma.serviceOrder.deleteMany({
          where: {
            id:
              serviceOrderBId,
          },
        });

        await prisma.equipment.deleteMany({
          where: {
            id:
              equipmentBId,
          },
        });

        await prisma.customerOrganization.deleteMany({
          where: {
            customerId:
              customerBId,
          },
        });

        await prisma.customer.deleteMany({
          where: {
            id:
              customerBId,
          },
        });

        await prisma.membership.deleteMany({
          where: {
            userId: {
              in: [
                adminAId,
                adminBId,
                userWithoutMembershipId,
              ],
            },
          },
        });

        await prisma.user.deleteMany({
          where: {
            id: {
              in: [
                adminAId,
                adminBId,
                userWithoutMembershipId,
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

        await app.close();

        if (oldJwtSecret) {
          process.env.JWT_SECRET =
            oldJwtSecret;
        } else {
          delete process.env.JWT_SECRET;
        }
      }
    );

    test(
      'ADMIN has a persisted Organization and Membership before authentication',
      async () => {
        const user =
          await prisma.user.findUnique({
            where: {
              id:
                adminAId,
            },

            include: {
              memberships: {
                include: {
                  organization:
                    true,
                },
              },
            },
          });

        assert.ok(
          user
        );

        assert.equal(
          user.status,
          UserStatus.ACTIVE
        );

        assert.equal(
          user.memberships.length,
          1
        );

        const membership =
          user.memberships[0];

        assert.equal(
          membership.organizationId,
          organizationAId
        );

        assert.equal(
          membership.role,
          Role.ADMIN
        );

        assert.equal(
          membership.organization.id,
          organizationAId
        );
      }
    );

    test(
      'valid ADMIN login returns JWT with role and organizationId derived from Membership',
      async () => {
        const response =
          await login(
            adminAEmail
          );

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.equal(
          typeof body.token,
          'string'
        );

        assert.equal(
          body.user.id,
          adminAId
        );

        assert.equal(
          body.user.role,
          Role.ADMIN
        );

        assert.equal(
          body.user.organizationId,
          organizationAId
        );

        const payload =
          (app as any)
            .jwt
            .verify(
              body.token
            ) as {
              sub: string;
              role: string;
              customerId:
              string | null;
              organizationId:
              string | null;
            };

        assert.equal(
          payload.sub,
          adminAId
        );

        assert.equal(
          payload.role,
          Role.ADMIN
        );

        assert.equal(
          payload.organizationId,
          organizationAId
        );

        assert.equal(
          payload.customerId,
          null
        );
      }
    );

    test(
      'invalid password is rejected',
      async () => {
        const response =
          await login(
            adminAEmail,
            'WrongPassword@123'
          );

        assert.equal(
          response.statusCode,
          401
        );

        assert.equal(
          response
            .json()
            .error,
          'Invalid credentials'
        );
      }
    );

    test(
      'ACTIVE user without Membership cannot authenticate into an organization context',
      async () => {
        const response =
          await login(
            userWithoutMembershipEmail
          );

        assert.equal(
          response.statusCode,
          403
        );

        assert.equal(
          response
            .json()
            .error,
          'User is not associated with an organization'
        );
      }
    );

    test(
      '/auth/me returns the authenticated user with the correct organizational Membership',
      async () => {
        const loginResponse =
          await login(
            adminAEmail
          );

        assert.equal(
          loginResponse.statusCode,
          200
        );

        const {
          token,
        } =
          loginResponse.json();

        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/api/v1/auth/me',

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.equal(
          body.user.id,
          adminAId
        );

        assert.equal(
          body.user.email,
          adminAEmail
        );

        assert.equal(
          body.user.role,
          Role.ADMIN
        );

        assert.equal(
          body.user.status,
          UserStatus.ACTIVE
        );

        assert.equal(
          body.user.memberships.length,
          1
        );

        assert.equal(
          body.user
            .memberships[0]
            .organizationId,
          organizationAId
        );

        assert.equal(
          body.user
            .memberships[0]
            .role,
          Role.ADMIN
        );
      }
    );

    test(
      'Organization A cannot access a Service Order owned by Organization B',
      async () => {
        const loginResponse =
          await login(
            adminAEmail
          );

        assert.equal(
          loginResponse.statusCode,
          200
        );

        const {
          token,
        } =
          loginResponse.json();

        const response =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/service-orders/${serviceOrderBId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          response.statusCode,
          404
        );

        assert.equal(
          response
            .json()
            .error,
          'Service Order not found'
        );
      }
    );

    test(
      'Organization B can access its own Service Order',
      async () => {
        const loginResponse =
          await login(
            adminBEmail
          );

        assert.equal(
          loginResponse.statusCode,
          200
        );

        const {
          token,
        } =
          loginResponse.json();

        const response =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/service-orders/${serviceOrderBId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.equal(
          body.order.id,
          serviceOrderBId
        );

        assert.equal(
          body.order.organizationId,
          organizationBId
        );

        assert.equal(
          body.order.customerId,
          customerBId
        );

        assert.equal(
          body.order.equipmentId,
          equipmentBId
        );
      }
    );
  }
);

/**
 * ============================================================
 * C3 — CUSTOMER ONBOARDING / LOGIN / GLOBAL HISTORY
 * ============================================================
 *
 * T026 → C03.04
 * T027 → C03.05
 * T028 → C03.06
 * T029 → C03.07
 */
describe(
  'C3 - Customer Onboarding, Authentication & Global Service Order History',
  {
    concurrency: false,
  },
  () => {
    let app:
      FastifyInstance;

    let oldJwtSecret:
      string | undefined;

    const runId =
      randomUUID();

    /**
     * ========================================================
     * ORGANIZATIONS
     * ========================================================
     */

    const organizationAId =
      randomUUID();

    const organizationBId =
      randomUUID();

    /**
     * ========================================================
     * ADMIN A
     * ========================================================
     */

    const adminAId =
      randomUUID();

    const adminAEmail =
      `c3-admin-a-${runId}@assistailab.test`;

    const adminPassword =
      'C3-Admin@123456';

    /**
     * ========================================================
     * CUSTOMER PRÉ-CADASTRADO
     * ========================================================
     */

    const onboardingCustomerId =
      randomUUID();

    const onboardingCustomerEmail =
      `c3-onboarding-${runId}@assistailab.test`;

    const onboardingEquipmentId =
      randomUUID();

    const onboardingOrderId =
      randomUUID();

    const onboardingPassword =
      'C3-Onboarding@123456';

    /**
     * ========================================================
     * CUSTOMER GLOBAL
     * ========================================================
     */

    const globalCustomerId =
      randomUUID();

    const globalCustomerUserId =
      randomUUID();

    const globalCustomerEmail =
      `c3-global-${runId}@assistailab.test`;

    const customerPassword =
      'C3-Customer@123456';

    const globalEquipmentAId =
      randomUUID();

    const globalEquipmentBId =
      randomUUID();

    const globalOrderAId =
      randomUUID();

    const globalOrderBId =
      randomUUID();

    /**
     * ========================================================
     * OUTRO CUSTOMER
     * ========================================================
     */

    const otherCustomerId =
      randomUUID();

    const otherCustomerEmail =
      `c3-other-${runId}@assistailab.test`;

    const otherEquipmentId =
      randomUUID();

    const otherOrderId =
      randomUUID();

    async function login(
      email: string,
      password: string
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

    before(
      async () => {
        oldJwtSecret =
          process.env.JWT_SECRET;

        process.env.JWT_SECRET =
          'c3-integration-test-secret-2026';

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
         * ORGANIZATIONS
         */

        await prisma.organization.create({
          data: {
            id:
              organizationAId,

            name:
              `C3 Organization A ${runId}`,
          },
        });

        await prisma.organization.create({
          data: {
            id:
              organizationBId,

            name:
              `C3 Organization B ${runId}`,
          },
        });

        /**
         * ADMIN A
         */

        await prisma.user.create({
          data: {
            id:
              adminAId,

            name:
              'C3 Admin A',

            email:
              adminAEmail,

            passwordHash:
              adminPasswordHash,

            role:
              Role.ADMIN,

            status:
              UserStatus.ACTIVE,
          },
        });

        await prisma.membership.create({
          data: {
            userId:
              adminAId,

            organizationId:
              organizationAId,

            role:
              Role.ADMIN,
          },
        });

        /**
         * ====================================================
         * CUSTOMER PRÉ-CADASTRADO
         * ====================================================
         *
         * Sem User.
         *
         * A conta será criada pelo onboarding.
         */

        await prisma.customer.create({
          data: {
            id:
              onboardingCustomerId,

            name:
              'Pedro Onboarding C3',

            email:
              onboardingCustomerEmail,

            phone:
              '16999990001',
          },
        });

        await prisma.customerOrganization.create({
          data: {
            customerId:
              onboardingCustomerId,

            organizationId:
              organizationAId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        await prisma.equipment.create({
          data: {
            id:
              onboardingEquipmentId,

            customerId:
              onboardingCustomerId,

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
              'C3 Onboarding Notebook',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id:
              onboardingOrderId,

            organizationId:
              organizationAId,

            customerId:
              onboardingCustomerId,

            equipmentId:
              onboardingEquipmentId,

            problemDescription:
              'Notebook não liga - C3 onboarding',
          },
        });

        /**
         * ====================================================
         * CUSTOMER GLOBAL
         * ====================================================
         */

        await prisma.customer.create({
          data: {
            id:
              globalCustomerId,

            name:
              'João Global C3',

            email:
              globalCustomerEmail,

            phone:
              '16999990002',
          },
        });

        /**
         * Não existe Membership para este User.
         */
        await prisma.user.create({
          data: {
            id:
              globalCustomerUserId,

            name:
              'João Global C3',

            email:
              globalCustomerEmail,

            passwordHash:
              customerPasswordHash,

            role:
              Role.CUSTOMER,

            status:
              UserStatus.ACTIVE,

            customerId:
              globalCustomerId,
          },
        });

        await prisma.customerOrganization.create({
          data: {
            customerId:
              globalCustomerId,

            organizationId:
              organizationAId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        await prisma.customerOrganization.create({
          data: {
            customerId:
              globalCustomerId,

            organizationId:
              organizationBId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        await prisma.equipment.create({
          data: {
            id:
              globalEquipmentAId,

            customerId:
              globalCustomerId,

            organizationId:
              null,

            ownerType:
              EquipmentOwnerType.CUSTOMER,

            organizationPurpose:
              null,

            type:
              'NOTEBOOK',

            brand:
              'Lenovo',

            model:
              'C3 Notebook A',
          },
        });

        await prisma.equipment.create({
          data: {
            id:
              globalEquipmentBId,

            customerId:
              globalCustomerId,

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
              'C3 Celular B',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id:
              globalOrderAId,

            organizationId:
              organizationAId,

            customerId:
              globalCustomerId,

            equipmentId:
              globalEquipmentAId,

            problemDescription:
              'Notebook não dá imagem',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id:
              globalOrderBId,

            organizationId:
              organizationBId,

            customerId:
              globalCustomerId,

            equipmentId:
              globalEquipmentBId,

            problemDescription:
              'Tela quebrada',
          },
        });

        /**
         * ====================================================
         * OUTRO CUSTOMER
         * ====================================================
         */

        await prisma.customer.create({
          data: {
            id:
              otherCustomerId,

            name:
              'Maria C3',

            email:
              otherCustomerEmail,
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
              'C3 Maria Notebook',
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
              'OS pertencente à Maria',
          },
        });

        app =
          buildApp();

        await app.ready();
      }
    );

    after(
      async () => {
        /**
         * Grant depende de Organization/User.
         */
        await prisma.accessGrant.deleteMany({
          where: {
            organizationId:
              organizationAId,

            type:
              AccessGrantType
                .CUSTOMER_ONBOARDING,
          },
        });

        /**
         * OS primeiro.
         */
        await prisma.serviceOrder.deleteMany({
          where: {
            id: {
              in: [
                onboardingOrderId,
                globalOrderAId,
                globalOrderBId,
                otherOrderId,
              ],
            },
          },
        });

        /**
         * Equipment.
         */
        await prisma.equipment.deleteMany({
          where: {
            id: {
              in: [
                onboardingEquipmentId,
                globalEquipmentAId,
                globalEquipmentBId,
                otherEquipmentId,
              ],
            },
          },
        });

        /**
         * Membership ADMIN.
         */
        await prisma.membership.deleteMany({
          where: {
            userId:
              adminAId,
          },
        });

        /**
         * Users.
         *
         * Inclui o User criado pelo claim.
         */
        await prisma.user.deleteMany({
          where: {
            OR: [
              {
                id: {
                  in: [
                    adminAId,
                    globalCustomerUserId,
                  ],
                },
              },

              {
                customerId:
                  onboardingCustomerId,
              },
            ],
          },
        });

        /**
         * Relationships.
         */
        await prisma.customerOrganization.deleteMany({
          where: {
            customerId: {
              in: [
                onboardingCustomerId,
                globalCustomerId,
                otherCustomerId,
              ],
            },
          },
        });

        /**
         * Customers.
         */
        await prisma.customer.deleteMany({
          where: {
            id: {
              in: [
                onboardingCustomerId,
                globalCustomerId,
                otherCustomerId,
              ],
            },
          },
        });

        /**
         * Organizations.
         */
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

        await app.close();

        if (oldJwtSecret) {
          process.env.JWT_SECRET =
            oldJwtSecret;
        } else {
          delete process.env.JWT_SECRET;
        }
      }
    );

    /**
     * ========================================================
     * T026 / C03.04
     * ========================================================
     */
    test(
      'Customer onboarding claim activates an account for the Customer resolved from the Service Order',
      async () => {
        const adminLogin =
          await login(
            adminAEmail,
            adminPassword
          );

        assert.equal(
          adminLogin.statusCode,
          200
        );

        const {
          token:
          adminToken,
        } =
          adminLogin.json();

        /**
         * A assistência gera o grant
         * a partir da própria OS.
         */
        const grantResponse =
          await app.inject({
            method:
              'POST',

            url:
              `/api/v1/auth/customer-onboarding/service-orders/${onboardingOrderId}/grant`,

            headers: {
              authorization:
                `Bearer ${adminToken}`,
            },
          });

        assert.equal(
          grantResponse.statusCode,
          201
        );

        const grantBody =
          grantResponse.json();

        assert.equal(
          typeof grantBody
            .grant
            .token,
          'string'
        );

        assert.ok(
          grantBody
            .grant
            .token
            .length >= 32
        );

        /**
         * Token bruto não é armazenado.
         */
        const persistedGrant =
          await prisma.accessGrant.findFirst({
            where: {
              organizationId:
                organizationAId,

              targetId:
                onboardingOrderId,

              type:
                AccessGrantType
                  .CUSTOMER_ONBOARDING,
            },

            orderBy: {
              createdAt:
                'desc',
            },
          });

        assert.ok(
          persistedGrant
        );

        assert.equal(
          persistedGrant.status,
          AccessGrantStatus.ACTIVE
        );

        assert.equal(
          persistedGrant
            .tokenHash
            .length,
          64
        );

        assert.notEqual(
          persistedGrant.tokenHash,
          grantBody.grant.token
        );

        /**
         * Cliente executa claim.
         */
        const claimResponse =
          await app.inject({
            method:
              'POST',

            url:
              '/api/v1/auth/customer-onboarding/claim',

            payload: {
              token:
                grantBody.grant.token,

              password:
                onboardingPassword,
            },
          });

        assert.equal(
          claimResponse.statusCode,
          200
        );

        const claimBody =
          claimResponse.json();

        assert.equal(
          claimBody.user.role,
          Role.CUSTOMER
        );

        assert.equal(
          claimBody.user.status,
          UserStatus.ACTIVE
        );

        assert.equal(
          claimBody.user.customerId,
          onboardingCustomerId
        );

        assert.equal(
          claimBody.user.email,
          onboardingCustomerEmail
        );

        /**
         * Confirma User persistido.
         */
        const activatedUser =
          await prisma.user.findUnique({
            where: {
              customerId:
                onboardingCustomerId,
            },

            include: {
              memberships:
                true,
            },
          });

        assert.ok(
          activatedUser
        );

        assert.equal(
          activatedUser.role,
          Role.CUSTOMER
        );

        assert.equal(
          activatedUser.status,
          UserStatus.ACTIVE
        );

        /**
         * CUSTOMER não precisa de Membership.
         */
        assert.equal(
          activatedUser
            .memberships
            .length,
          0
        );

        /**
         * Grant é one-shot.
         */
        const usedGrant =
          await prisma.accessGrant.findUnique({
            where: {
              id:
                persistedGrant.id,
            },
          });

        assert.ok(
          usedGrant
        );

        assert.equal(
          usedGrant.status,
          AccessGrantStatus.USED
        );

        assert.ok(
          usedGrant.usedAt
        );

        /**
         * Reutilização é rejeitada.
         */
        const secondClaim =
          await app.inject({
            method:
              'POST',

            url:
              '/api/v1/auth/customer-onboarding/claim',

            payload: {
              token:
                grantBody.grant.token,

              password:
                onboardingPassword,
            },
          });

        assert.equal(
          secondClaim.statusCode,
          409
        );

        /**
         * Conta criada já pode logar.
         */
        const customerLogin =
          await login(
            onboardingCustomerEmail,
            onboardingPassword
          );

        assert.equal(
          customerLogin.statusCode,
          200
        );

        const customerLoginBody =
          customerLogin.json();

        assert.equal(
          customerLoginBody
            .user
            .customerId,
          onboardingCustomerId
        );

        assert.equal(
          customerLoginBody
            .user
            .organizationId,
          null
        );
      }
    );

    /**
     * ========================================================
     * T027 / C03.05
     * ========================================================
     */
    test(
      'ACTIVE CUSTOMER can authenticate without Membership and receives a global Customer JWT',
      async () => {
        const membershipCount =
          await prisma.membership.count({
            where: {
              userId:
                globalCustomerUserId,
            },
          });

        assert.equal(
          membershipCount,
          0
        );

        const response =
          await login(
            globalCustomerEmail,
            customerPassword
          );

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.equal(
          body.user.id,
          globalCustomerUserId
        );

        assert.equal(
          body.user.role,
          Role.CUSTOMER
        );

        assert.equal(
          body.user.customerId,
          globalCustomerId
        );

        assert.equal(
          body.user.organizationId,
          null
        );

        const payload =
          (app as any)
            .jwt
            .verify(
              body.token
            ) as {
              sub: string;
              role: string;
              customerId:
              string | null;
              organizationId:
              string | null;
            };

        assert.equal(
          payload.sub,
          globalCustomerUserId
        );

        assert.equal(
          payload.role,
          Role.CUSTOMER
        );

        assert.equal(
          payload.customerId,
          globalCustomerId
        );

        assert.equal(
          payload.organizationId,
          null
        );

        /**
         * /auth/me também precisa funcionar
         * sem Membership.
         */
        const meResponse =
          await app.inject({
            method:
              'GET',

            url:
              '/api/v1/auth/me',

            headers: {
              authorization:
                `Bearer ${body.token}`,
            },
          });

        assert.equal(
          meResponse.statusCode,
          200
        );

        const meBody =
          meResponse.json();

        assert.equal(
          meBody.user.customerId,
          globalCustomerId
        );

        assert.equal(
          meBody.user.role,
          Role.CUSTOMER
        );

        assert.equal(
          meBody.user.organizationId,
          null
        );
      }
    );

    /**
     * ========================================================
     * T028 / C03.06
     * ========================================================
     */
    test(
      'CUSTOMER can access own Service Order but cannot access another Customer Service Order',
      async () => {
        const loginResponse =
          await login(
            globalCustomerEmail,
            customerPassword
          );

        assert.equal(
          loginResponse.statusCode,
          200
        );

        const {
          token,
        } =
          loginResponse.json();

        /**
         * Própria OS.
         */
        const ownResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/service-orders/${globalOrderAId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          ownResponse.statusCode,
          200
        );

        const ownBody =
          ownResponse.json();

        assert.equal(
          ownBody.order.id,
          globalOrderAId
        );

        assert.equal(
          ownBody.order.customerId,
          globalCustomerId
        );

        /**
         * OS de outro Customer.
         */
        const foreignResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/service-orders/${otherOrderId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          foreignResponse.statusCode,
          404
        );

        assert.equal(
          foreignResponse
            .json()
            .error,
          'Service Order not found'
        );
      }
    );

    /**
     * ========================================================
     * T029 / C03.07
     * ========================================================
     *
     * João possui:
     *
     * Organization A → OS A
     * Organization B → OS B
     *
     * As duas precisam aparecer.
     */
    test(
      'CUSTOMER global history returns own Service Orders from multiple Organizations only',
      async () => {
        const loginResponse =
          await login(
            globalCustomerEmail,
            customerPassword
          );

        assert.equal(
          loginResponse.statusCode,
          200
        );

        const {
          token,
        } =
          loginResponse.json();

        const response =
          await app.inject({
            method:
              'GET',

            url:
              '/api/v1/service-orders',

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          response.statusCode,
          200
        );

        const body =
          response.json();

        assert.ok(
          Array.isArray(
            body.orders
          )
        );

        const orderIds =
          new Set<string>(
            body.orders.map(
              (
                order:
                  { id: string }
              ) =>
                order.id
            )
          );

        /**
         * Próprias OS A + B.
         */
        assert.equal(
          orderIds.has(
            globalOrderAId
          ),
          true
        );

        assert.equal(
          orderIds.has(
            globalOrderBId
          ),
          true
        );

        /**
         * Maria não aparece.
         */
        assert.equal(
          orderIds.has(
            otherOrderId
          ),
          false
        );

        /**
         * Nenhuma OS alheia pode aparecer.
         */
        assert.ok(
          body.orders.every(
            (
              order:
                {
                  customerId:
                  string;
                }
            ) =>
              order.customerId ===
              globalCustomerId
          )
        );

        /**
         * Prova explícita de duas Organizations.
         */
        const ownOrders =
          body.orders.filter(
            (
              order:
                { id: string }
            ) =>
              order.id ===
              globalOrderAId ||
              order.id ===
              globalOrderBId
          );

        const organizationIds =
          new Set<string>(
            ownOrders.map(
              (
                order:
                  {
                    organizationId:
                    string;
                  }
              ) =>
                order.organizationId
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
      }
    );
  }
);