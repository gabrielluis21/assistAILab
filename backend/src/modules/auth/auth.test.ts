import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import bcrypt from 'bcrypt';

import {
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

/**
 * C1 — Organização adquire/acessa o sistema.
 *
 * Escopo atualmente implementado:
 *
 * C01.01 JWT_SECRET obrigatório             -> já coberto
 * C01.02 sem privilege escalation           -> já coberto
 * C01.03 Organization existente             -> esta suíte
 * C01.04 Membership obrigatória              -> esta suíte
 * C01.05 Login + JWT com contexto correto    -> esta suíte
 * C01.06 Credenciais inválidas               -> esta suíte
 * C01.07 /auth/me                            -> esta suíte
 * C01.08 isolamento entre Organizations      -> esta suíte
 *
 * C01.09 Licenciamento                       -> ainda não implementado
 * C01.10 Login Flutter Desktop/Web/Mobile    -> ainda não implementado
 */

describe(
  'C1 - Organization Authentication & Tenant Isolation',
  {
    concurrency: false,
  },
  () => {
    let app: FastifyInstance;

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

    let oldJwtSecret:
      string | undefined;

    /**
     * Helper de login.
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

    before(
      async () => {
        /**
         * A suíte precisa de JWT_SECRET,
         * mas não deve depender do .env
         * da máquina.
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
         * --------------------------------
         * ORGANIZATIONS
         * --------------------------------
         */

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

        /**
         * --------------------------------
         * USERS
         * --------------------------------
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
         * Usuário ACTIVE propositalmente
         * sem Membership.
         *
         * Será usado para provar que apenas
         * ter uma conta ativa não concede
         * contexto organizacional.
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
         * --------------------------------
         * MEMBERSHIPS
         * --------------------------------
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
         * --------------------------------
         * DADO PROTEGIDO DA ORGANIZATION B
         * --------------------------------
         *
         * Criamos uma OS real da Organization B
         * para testar isolamento multi-tenant.
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

            ownerType:
              'CUSTOMER',

            organizationId:
              null,

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
         * de prepararmos a configuração.
         */
        app =
          buildApp();

        await app.ready();
      }
    );

    after(
      async () => {
        /**
         * Cleanup na ordem inversa
         * das dependências.
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

        if (app) {
          await app.close();
        }

        /**
         * Restaura ambiente original.
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
     * C01.03 + C01.04
     *
     * Prova que o usuário organizacional
     * possui uma Organization persistida
     * e uma Membership válida apontando
     * para ela.
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
     * C01.05
     *
     * O contexto privilegiado do JWT
     * deve vir do backend/Membership.
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
         * Verifica também o conteúdo
         * efetivamente assinado no JWT.
         */
        const payload =
          (
            app as any
          ).jwt.verify(
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
     * C01.06
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
     * C01.04
     *
     * Conta ACTIVE isoladamente não basta.
     * O usuário precisa estar associado
     * a uma Organization.
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
     * C01.07
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
      }
    );

    /**
     * C01.08
     *
     * Organization A NÃO pode acessar
     * recurso protegido pertencente à B.
     *
     * ServiceOrder já possui isolamento
     * explícito por organizationId no
     * backend.
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
         * O backend deliberadamente
         * não encontra recursos de outro
         * tenant no contexto corrente.
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
     * Contraprova do teste anterior.
     *
     * Não basta provar que A recebe 404:
     * precisamos provar que a OS existe
     * e B consegue acessá-la.
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