import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import bcrypt from 'bcrypt';

import {
  AccessGrantStatus,
  AccessGrantType,
  CustomerOrganizationStatus,
  EquipmentOwnerType,
  Role,
  UserStatus,
} from '@prisma/client';

import {
  randomUUID,
} from 'node:crypto';

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
  registerSchema,
} from './auth.schema.js';

/**
 * ============================================================
 * AUTH SECURITY
 * ============================================================
 *
 * Testes de segurança existentes antes da expansão do C1.
 *
 * Eles continuam importantes porque cobrem:
 *
 * C01.01
 * - JWT_SECRET obrigatório.
 *
 * C01.02
 * - cadastro público não pode injetar role.
 *
 * C03
 * - validações básicas do cadastro público de Customer.
 */
describe(
  'Auth Security & Privilege Escalation Hardening',
  () => {
    /**
     * C01.01
     *
     * O backend não pode iniciar sem
     * segredo JWT configurado.
     */
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

    /**
     * C01.02 / C03
     *
     * Dados enviados pelo client representam
     * intenção, nunca autoridade.
     *
     * O cadastro público não pode aceitar
     * role privilegiada.
     */
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

        /**
         * O Zod remove propriedades
         * desconhecidas.
         *
         * Portanto o payload continua válido,
         * mas role NÃO pode sobreviver ao parse.
         */
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

    /**
     * C03
     */
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

    /**
     * C03
     */
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

          /**
           * organizationId propositalmente
           * enviado para garantir que ele
           * não quebra o cadastro e também
           * não é aceito como autoridade.
           */
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
 * Escopo atualmente implementado:
 *
 * C01.01 JWT_SECRET obrigatório
 *         → Auth Security
 *
 * C01.02 sem privilege escalation
 *         → Auth Security
 *
 * C01.03 Organization existente
 *         → esta suíte
 *
 * C01.04 Membership obrigatória
 *         → esta suíte
 *
 * C01.05 Login + JWT com contexto correto
 *         → esta suíte
 *
 * C01.06 Credenciais inválidas
 *         → esta suíte
 *
 * C01.07 /auth/me
 *         → esta suíte
 *
 * C01.08 isolamento entre Organizations
 *         → esta suíte
 *
 * C01.09 Licenciamento
 *         → ainda não implementado
 *
 * C01.10 Login Flutter Desktop/Web/Mobile
 *         → ainda não implementado
 */
describe(
  'C1 - Organization Authentication & Tenant Isolation',
  {
    concurrency: false,
  },
  () => {
    let app:
      FastifyInstance;

    const runId =
      randomUUID();

    /**
     * --------------------------------------------------------
     * ORGANIZATIONS
     * --------------------------------------------------------
     */

    const organizationAId =
      randomUUID();

    const organizationBId =
      randomUUID();

    /**
     * --------------------------------------------------------
     * USERS
     * --------------------------------------------------------
     */

    const adminAId =
      randomUUID();

    const adminBId =
      randomUUID();

    const userWithoutMembershipId =
      randomUUID();

    /**
     * --------------------------------------------------------
     * RECURSO DA ORGANIZATION B
     * --------------------------------------------------------
     *
     * Utilizado para provar isolamento
     * multi-tenant.
     */

    const customerBId =
      randomUUID();

    const equipmentBId =
      randomUUID();

    const serviceOrderBId =
      randomUUID();

    /**
     * --------------------------------------------------------
     * CREDENTIALS
     * --------------------------------------------------------
     */

    const adminAEmail =
      `c1-admin-a-${runId}@assistailab.test`;

    const adminBEmail =
      `c1-admin-b-${runId}@assistailab.test`;

    const userWithoutMembershipEmail =
      `c1-no-membership-${runId}@assistailab.test`;

    const password =
      'C1-Test@123456';

    let oldJwtSecret:
      string | undefined;

    /**
     * Helper utilizado pelos testes
     * que precisam autenticar um usuário.
     */
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

    /**
     * ========================================================
     * SETUP
     * ========================================================
     */
    before(
      async () => {
        /**
         * Não dependemos do JWT_SECRET
         * configurado na máquina de desenvolvimento.
         */
        oldJwtSecret =
          process.env.JWT_SECRET;

        process.env.JWT_SECRET =
          'c1-integration-test-secret-2026';

        const passwordHash =
          await bcrypt.hash(
            password,
            12
          );

        /**
         * ----------------------------------------------------
         * ORGANIZATION A
         * ----------------------------------------------------
         */
        await prisma.organization.create({
          data: {
            id:
              organizationAId,

            name:
              `C1 Organization A ${runId}`,
          },
        });

        /**
         * ----------------------------------------------------
         * ORGANIZATION B
         * ----------------------------------------------------
         */
        await prisma.organization.create({
          data: {
            id:
              organizationBId,

            name:
              `C1 Organization B ${runId}`,
          },
        });

        /**
         * ----------------------------------------------------
         * ADMIN A
         * ----------------------------------------------------
         */
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

        /**
         * ----------------------------------------------------
         * ADMIN B
         * ----------------------------------------------------
         */
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

        /**
         * ----------------------------------------------------
         * ACTIVE SEM MEMBERSHIP
         * ----------------------------------------------------
         *
         * Este usuário existe propositalmente
         * para provar que:
         *
         * User ACTIVE != acesso organizacional.
         */
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

        /**
         * ----------------------------------------------------
         * MEMBERSHIP A
         * ----------------------------------------------------
         */
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
         * ----------------------------------------------------
         * MEMBERSHIP B
         * ----------------------------------------------------
         */
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

        /**
         * ====================================================
         * RECURSO PROTEGIDO DA ORGANIZATION B
         * ====================================================
         *
         * Customer + Equipment + ServiceOrder
         * pertencentes ao contexto da Organization B.
         */

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
              'ACTIVE',
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

        /**
         * Inicializa Fastify somente depois
         * de preparar as fixtures.
         */
        app =
          buildApp();

        await app.ready();
      }
    );

    /**
     * ========================================================
     * CLEANUP
     * ========================================================
     */
    after(
      async () => {
        /**
         * Ordem inversa das dependências.
         */

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

        /**
         * Restaura JWT_SECRET original.
         */
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
     * C01.03 + C01.04
     * ========================================================
     *
     * Prova:
     *
     * User
     *   ↓
     * Membership
     *   ↓
     * Organization
     */
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

    /**
     * ========================================================
     * C01.05
     * ========================================================
     *
     * Login válido precisa gerar um JWT
     * cujo contexto privilegiado venha
     * do backend/Membership.
     */
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

        /**
         * Confere também o JWT efetivamente
         * assinado pelo Fastify.
         */
        const payload =
          (app as any).jwt.verify(
            body.token
          ) as {
            sub: string;
            role: string;
            customerId:
            string | null;
            organizationId:
            string;
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

    /**
     * ========================================================
     * C01.06
     * ========================================================
     */
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

        const body =
          response.json();

        assert.equal(
          body.error,
          'Invalid credentials'
        );
      }
    );

    /**
     * ========================================================
     * C01.04
     * ========================================================
     *
     * User ACTIVE não basta.
     *
     * É necessário existir Membership
     * vinculando o usuário à Organization.
     */
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

        const body =
          response.json();

        assert.equal(
          body.error,
          'User is not associated with an organization'
        );
      }
    );

    /**
     * ========================================================
     * C01.07
     * ========================================================
     */
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
          body.user.memberships[0]
            .organizationId,
          organizationAId
        );

        assert.equal(
          body.user.memberships[0]
            .role,
          Role.ADMIN
        );
      }
    );

    /**
     * ========================================================
     * C01.08
     * ========================================================
     *
     * Organization A não pode enxergar
     * uma ServiceOrder da Organization B.
     */
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

        /**
         * O recurso de outro tenant
         * não deve ser exposto.
         */
        assert.equal(
          response.statusCode,
          404
        );

        const body =
          response.json();

        assert.equal(
          body.error,
          'Service Order not found'
        );
      }
    );

    /**
     * Contraprova do isolamento.
     *
     * Precisamos provar que a OS realmente
     * existe e que sua Organization legítima
     * consegue acessá-la.
     */
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
     * ADMIN
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
     * CUSTOMER PARA ONBOARDING
     * ========================================================
     *
     * Representa o fluxo real:
     *
     * assistência pré-cadastra Customer
     *          ↓
     * abre OS
     *          ↓
     * gera QR/token
     *          ↓
     * Customer cria/ativa sua conta
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
     *
     * Este Customer já possui conta ACTIVE,
     * mas NÃO possui Membership.
     *
     * Ele possui OS:
     *
     * Organization A
     * Organization B
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
     *
     * Usado para provar que João não consegue
     * acessar a OS de Maria.
     */

    const otherCustomerId =
      randomUUID();

    const otherCustomerEmail =
      `c3-other-${runId}@assistailab.test`;

    const otherEquipmentId =
      randomUUID();

    const otherOrderId =
      randomUUID();

    /**
     * ========================================================
     * HELPERS
     * ========================================================
     */

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

    /**
     * ========================================================
     * SETUP
     * ========================================================
     */

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
         * ----------------------------------------------------
         * ORGANIZATIONS
         * ----------------------------------------------------
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
         * ----------------------------------------------------
         * ADMIN A
         * ----------------------------------------------------
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
         * CUSTOMER PRÉ-CADASTRADO PARA ONBOARDING
         * ====================================================
         *
         * Importante:
         *
         * NÃO criamos User.
         *
         * A conta será criada pelo claim.
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
         * Conta global.
         *
         * NÃO existe Membership.
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

        /**
         * João possui relação com A e B.
         */
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

        /**
         * Equipment atendido por A.
         */
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

        /**
         * Equipment atendido por B.
         */
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

        /**
         * Fastify depois das fixtures.
         */
        app =
          buildApp();

        await app.ready();
      }
    );

    /**
     * ========================================================
     * CLEANUP
     * ========================================================
     */

    after(
      async () => {
        /**
         * Grants primeiro.
         */
        await prisma.accessGrant.deleteMany({
          where: {
            OR: [
              {
                targetId:
                  onboardingOrderId,
              },

              {
                organizationId:
                  organizationAId,

                type:
                  AccessGrantType.CUSTOMER_ONBOARDING,
              },
            ],
          },
        });

        /**
         * Service Orders.
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
         * Membership do ADMIN.
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
         * Inclui o User criado dinamicamente
         * pelo onboarding.
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
         * CustomerOrganization.
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
     * C03.04
     * ========================================================
     *
     * Customer pré-cadastrado:
     *
     * Customer
     *   ↓
     * ServiceOrder
     *   ↓
     * CUSTOMER_ONBOARDING
     *   ↓
     * User ACTIVE
     */
    test(
      'Customer onboarding claim activates an account for the Customer resolved from the Service Order',
      async () => {
        /**
         * Login ADMIN.
         */
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
         * Gera grant.
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
         * Banco possui somente hash.
         */
        const grant =
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
          grant
        );

        assert.equal(
          grant.status,
          AccessGrantStatus.ACTIVE
        );

        assert.equal(
          grant.tokenHash.length,
          64
        );

        assert.notEqual(
          grant.tokenHash,
          grantBody.grant.token
        );

        /**
         * Customer executa o claim.
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
         * Confirma persistência.
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
          activatedUser.status,
          UserStatus.ACTIVE
        );

        assert.equal(
          activatedUser.role,
          Role.CUSTOMER
        );

        /**
         * CUSTOMER global NÃO precisa
         * de Membership.
         */
        assert.equal(
          activatedUser
            .memberships
            .length,
          0
        );

        /**
         * Grant virou USED.
         */
        const usedGrant =
          await prisma.accessGrant.findUnique({
            where: {
              id:
                grant.id,
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
         * Token é de uso único.
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
         * Conta criada pelo onboarding
         * já consegue autenticar.
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

        assert.equal(
          customerLogin
            .json()
            .user
            .customerId,
          onboardingCustomerId
        );

        assert.equal(
          customerLogin
            .json()
            .user
            .organizationId,
          null
        );
      }
    );

    /**
     * ========================================================
     * C03.05
     * ========================================================
     *
     * CUSTOMER ACTIVE autentica somente com:
     *
     * User
     *   +
     * customerId
     *
     * Membership NÃO é necessária.
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

        /**
         * CUSTOMER não fica preso
         * a uma Organization.
         */
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
         * /auth/me também deve funcionar
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
     * C03.06
     * ========================================================
     *
     * João não acessa OS da Maria.
     *
     * Retornamos 404 para não revelar
     * a existência do recurso.
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
         * OS da Maria.
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
     * C03.07
     * ========================================================
     *
     * Customer possui visão global.
     *
     * João:
     *
     * Organization A → OS A
     * Organization B → OS B
     *
     * Ambas precisam aparecer.
     *
     * OS da Maria não pode aparecer.
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
          new Set(
            body.orders.map(
              (
                order:
                  { id: string }
              ) =>
                order.id
            )
          );

        /**
         * Próprias OS das duas assistências.
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
         * OS alheia nunca aparece.
         */
        assert.equal(
          orderIds.has(
            otherOrderId
          ),
          false
        );

        /**
         * Nenhuma OS retornada pode
         * pertencer a outro Customer.
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
         * Confirma explicitamente
         * visão multi-Organization.
         */
        const organizationIds =
          new Set(
            body.orders
              .filter(
                (
                  order:
                    {
                      id: string;
                    }
                ) =>
                  order.id ===
                  globalOrderAId ||
                  order.id ===
                  globalOrderBId
              )
              .map(
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