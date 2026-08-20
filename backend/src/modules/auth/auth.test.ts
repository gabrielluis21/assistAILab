import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import bcrypt from 'bcrypt';

import {
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