import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import bcrypt from 'bcrypt';

import {
  CustomerOrganizationStatus,
  EquipmentOwnerType,
  Role,
  ServiceOrderStatus,
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
import { isValidStatusTransition } from './service_order_state_machine.js';

/**
 * ============================================================
 * C2 — CUSTOMER + EQUIPMENT + SERVICE ORDER
 * ============================================================
 *
 * Cenário mestre:
 *
 * Cliente chega à assistência e abre OS para:
 *
 * - Notebook
 * - Celular
 *
 * Regras já aprovadas e implementadas:
 *
 * C02.01
 * Customer precisa possuir CustomerOrganization ACTIVE.
 *
 * C02.02
 * Equipment precisa pertencer ao mesmo Customer da OS.
 *
 * C02.03
 * ServiceOrder deve possuir:
 *
 * Organization
 * Customer
 * Equipment
 *
 * sendo Organization determinada pelo backend/JWT.
 *
 * C02.06
 * Estados operacionais não geram eventos CRM indevidos.
 * → já coberto por T008.
 *
 * C02.07
 * Isolamento entre Organizations.
 * → já parcialmente coberto por T018/T019.
 *
 * C02.08
 * Mesmo Customer pode possuir OS diferentes para
 * Notebook e Celular.
 *
 * ------------------------------------------------------------
 *
 * C02.04 e C02.05 NÃO são implementados nesta suíte.
 *
 * O módulo Equipment ainda precisa ser alinhado à regra:
 *
 * Organization só acessa Equipment de Customer através de OS.
 *
 * A decisão sobre o cadastro do Equipment antes da primeira OS
 * será discutida separadamente antes de alterar a implementação.
 */
describe('Service Order State Machine Hardening', () => {
  test('Valid state transitions pass', () => {
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DRAFT, ServiceOrderStatus.DIAGNOSTICO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DIAGNOSTICO, ServiceOrderStatus.AGUARDANDO_APROVACAO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.AGUARDANDO_APROVACAO, ServiceOrderStatus.EM_EXECUCAO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.EM_EXECUCAO, ServiceOrderStatus.PRONTO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.PRONTO, ServiceOrderStatus.ENTREGUE), true);
  });

  test('Cancellation from valid states is allowed', () => {
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DRAFT, ServiceOrderStatus.CANCELADO), true);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DIAGNOSTICO, ServiceOrderStatus.CANCELADO), true);
  });

  test('Invalid backward or skipped transitions are rejected', () => {
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.ENTREGUE, ServiceOrderStatus.DIAGNOSTICO), false);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.CANCELADO, ServiceOrderStatus.EM_EXECUCAO), false);
    assert.strictEqual(isValidStatusTransition(ServiceOrderStatus.DRAFT, ServiceOrderStatus.ENTREGUE), false);
  });
});

describe(
  'C2 - Customer Equipment & Service Order Integration',
  {
    concurrency: false,
  },
  () => {
    let app:
      FastifyInstance;

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
     * ADMINS
     * ========================================================
     */

    const adminAId =
      randomUUID();

    const adminBId =
      randomUUID();

    const adminAEmail =
      `c2-admin-a-${runId}@assistailab.test`;

    const adminBEmail =
      `c2-admin-b-${runId}@assistailab.test`;

    const password =
      'C2-Test@123456';

    /**
     * ========================================================
     * CUSTOMERS
     * ========================================================
     *
     * João:
     * cliente normal ACTIVE da Organization A.
     *
     * Maria:
     * outro cliente ACTIVE da Organization A.
     *
     * Carlos:
     * relacionamento BLOCKED com Organization A.
     */

    const customerJoaoId =
      randomUUID();

    const customerMariaId =
      randomUUID();

    const customerBlockedId =
      randomUUID();

    /**
     * ========================================================
     * EQUIPMENTS
     * ========================================================
     */

    const notebookJoaoId =
      randomUUID();

    const celularJoaoId =
      randomUUID();

    const notebookMariaId =
      randomUUID();

    const notebookBlockedId =
      randomUUID();

    /**
     * Guarda OS criadas pela própria suíte
     * para cleanup seguro.
     */
    const createdOrderIds:
      string[] = [];

    /**
     * ========================================================
     * LOGIN HELPER
     * ========================================================
     */

    async function login(
      email: string
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
     * CREATE OS HELPER
     * ========================================================
     */

    async function createOrder(
      token: string,
      customerId: string,
      equipmentId: string,
      problemDescription: string
    ) {
      return app.inject({
        method:
          'POST',

        url:
          '/api/v1/service-orders',

        headers: {
          authorization:
            `Bearer ${token}`,
        },

        payload: {
          customerId,
          equipmentId,
          problemDescription,
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
        process.env.JWT_SECRET =
          process.env.JWT_SECRET ??
          'c2-integration-test-secret-2026';

        const passwordHash =
          await bcrypt.hash(
            password,
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
              `C2 Organization A ${runId}`,
          },
        });

        await prisma.organization.create({
          data: {
            id:
              organizationBId,

            name:
              `C2 Organization B ${runId}`,
          },
        });

        /**
         * ----------------------------------------------------
         * ADMINS
         * ----------------------------------------------------
         */

        await prisma.user.create({
          data: {
            id:
              adminAId,

            name:
              'C2 Admin A',

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
              'C2 Admin B',

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
         * MEMBERSHIPS
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
         * ----------------------------------------------------
         * CUSTOMERS
         * ----------------------------------------------------
         */

        await prisma.customer.create({
          data: {
            id:
              customerJoaoId,

            name:
              'João C2',

            email:
              `joao-${runId}@assistailab.test`,
          },
        });

        await prisma.customer.create({
          data: {
            id:
              customerMariaId,

            name:
              'Maria C2',

            email:
              `maria-${runId}@assistailab.test`,
          },
        });

        await prisma.customer.create({
          data: {
            id:
              customerBlockedId,

            name:
              'Carlos Blocked C2',

            email:
              `blocked-${runId}@assistailab.test`,
          },
        });

        /**
         * ----------------------------------------------------
         * CUSTOMER ORGANIZATION
         * ----------------------------------------------------
         */

        await prisma.customerOrganization.create({
          data: {
            customerId:
              customerJoaoId,

            organizationId:
              organizationAId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        await prisma.customerOrganization.create({
          data: {
            customerId:
              customerMariaId,

            organizationId:
              organizationAId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        /**
         * Cliente existente, porém bloqueado.
         */
        await prisma.customerOrganization.create({
          data: {
            customerId:
              customerBlockedId,

            organizationId:
              organizationAId,

            status:
              CustomerOrganizationStatus.BLOCKED,
          },
        });

        /**
         * ====================================================
         * EQUIPMENTS — JOÃO
         * ====================================================
         */

        await prisma.equipment.create({
          data: {
            id:
              notebookJoaoId,

            customerId:
              customerJoaoId,

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
              'Inspiron C2',
          },
        });

        await prisma.equipment.create({
          data: {
            id:
              celularJoaoId,

            customerId:
              customerJoaoId,

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
              'Galaxy C2',
          },
        });

        /**
         * ====================================================
         * EQUIPMENT — MARIA
         * ====================================================
         */

        await prisma.equipment.create({
          data: {
            id:
              notebookMariaId,

            customerId:
              customerMariaId,

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
              'IdeaPad C2',
          },
        });

        /**
         * ====================================================
         * EQUIPMENT — CUSTOMER BLOCKED
         * ====================================================
         */

        await prisma.equipment.create({
          data: {
            id:
              notebookBlockedId,

            customerId:
              customerBlockedId,

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
              'Blocked C2',
          },
        });

        /**
         * Inicializa Fastify somente depois
         * das fixtures estarem prontas.
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
         * ServiceOrders primeiro porque
         * possuem FK Restrict para Equipment
         * e Customer.
         */

        if (
          createdOrderIds.length >
          0
        ) {
          await prisma.serviceOrder.deleteMany({
            where: {
              id: {
                in:
                  createdOrderIds,
              },
            },
          });
        }

        /**
         * Eventos CRM criados pelas OS
         * são removidos ao excluir os Customers.
         *
         * CustomerProfile pertence a
         * CustomerOrganization e será removido
         * pelo Cascade correspondente.
         */

        await prisma.equipment.deleteMany({
          where: {
            id: {
              in: [
                notebookJoaoId,
                celularJoaoId,
                notebookMariaId,
                notebookBlockedId,
              ],
            },
          },
        });

        await prisma.customerOrganization.deleteMany({
          where: {
            customerId: {
              in: [
                customerJoaoId,
                customerMariaId,
                customerBlockedId,
              ],
            },
          },
        });

        await prisma.customer.deleteMany({
          where: {
            id: {
              in: [
                customerJoaoId,
                customerMariaId,
                customerBlockedId,
              ],
            },
          },
        });

        await prisma.membership.deleteMany({
          where: {
            userId: {
              in: [
                adminAId,
                adminBId,
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
      }
    );

    /**
     * ========================================================
     * C02.01 + C02.03 + C02.08
     * ========================================================
     *
     * João possui:
     *
     * - Notebook
     * - Celular
     *
     * Organization A abre uma OS para cada
     * equipamento.
     *
     * Também validamos que organizationId
     * vem do contexto autenticado.
     */

    test(
      'ACTIVE customer can open separate Service Orders for Notebook and Cellphone in the authenticated Organization',
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

        /**
         * ----------------------------------------------------
         * NOTEBOOK
         * ----------------------------------------------------
         */

        const notebookResponse =
          await createOrder(
            token,
            customerJoaoId,
            notebookJoaoId,
            'Notebook não inicializa'
          );

        assert.equal(
          notebookResponse.statusCode,
          201
        );

        const notebookBody =
          notebookResponse.json();

        createdOrderIds.push(
          notebookBody.order.id
        );

        assert.equal(
          notebookBody.order.organizationId,
          organizationAId
        );

        assert.equal(
          notebookBody.order.customerId,
          customerJoaoId
        );

        assert.equal(
          notebookBody.order.equipmentId,
          notebookJoaoId
        );

        assert.equal(
          notebookBody.order.status,
          ServiceOrderStatus.DIAGNOSTICO
        );

        /**
         * ----------------------------------------------------
         * CELULAR
         * ----------------------------------------------------
         */

        const celularResponse =
          await createOrder(
            token,
            customerJoaoId,
            celularJoaoId,
            'Celular não carrega'
          );

        assert.equal(
          celularResponse.statusCode,
          201
        );

        const celularBody =
          celularResponse.json();

        createdOrderIds.push(
          celularBody.order.id
        );

        assert.equal(
          celularBody.order.organizationId,
          organizationAId
        );

        assert.equal(
          celularBody.order.customerId,
          customerJoaoId
        );

        assert.equal(
          celularBody.order.equipmentId,
          celularJoaoId
        );

        assert.equal(
          celularBody.order.status,
          ServiceOrderStatus.DIAGNOSTICO
        );

        /**
         * São duas OS distintas.
         */
        assert.notEqual(
          notebookBody.order.id,
          celularBody.order.id
        );

        /**
         * Confirma também diretamente
         * no banco.
         */
        const orders =
          await prisma.serviceOrder.findMany({
            where: {
              id: {
                in: [
                  notebookBody.order.id,
                  celularBody.order.id,
                ],
              },
            },

            orderBy: {
              createdAt:
                'asc',
            },
          });

        assert.equal(
          orders.length,
          2
        );

        assert.ok(
          orders.every(
            (order) =>
              order.organizationId ===
              organizationAId
          )
        );

        assert.ok(
          orders.every(
            (order) =>
              order.customerId ===
              customerJoaoId
          )
        );
      }
    );

    /**
     * ========================================================
     * C02.01
     * ========================================================
     *
     * CustomerOrganization existente,
     * porém BLOCKED.
     *
     * Não pode abrir OS.
     */

    test(
      'BLOCKED CustomerOrganization cannot open a Service Order',
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
          await createOrder(
            token,
            customerBlockedId,
            notebookBlockedId,
            'Tentativa de OS para cliente bloqueado'
          );

        assert.equal(
          response.statusCode,
          403
        );

        const body =
          response.json();

        assert.equal(
          body.error,
          'Customer relationship with the current organization is not active'
        );

        const orderCount =
          await prisma.serviceOrder.count({
            where: {
              organizationId:
                organizationAId,

              customerId:
                customerBlockedId,
            },
          });

        assert.equal(
          orderCount,
          0
        );
      }
    );

    /**
     * ========================================================
     * C02.02
     * ========================================================
     *
     * Não é permitido criar:
     *
     * Customer = João
     * Equipment = Notebook da Maria
     */

    test(
      'Service Order rejects Equipment that belongs to another Customer',
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
          await createOrder(
            token,
            customerJoaoId,
            notebookMariaId,
            'Tentativa de usar equipamento de outro cliente'
          );

        assert.equal(
          response.statusCode,
          403
        );

        const body =
          response.json();

        assert.equal(
          body.error,
          'Equipment does not belong to the specified customer'
        );

        const invalidOrder =
          await prisma.serviceOrder.findFirst({
            where: {
              organizationId:
                organizationAId,

              customerId:
                customerJoaoId,

              equipmentId:
                notebookMariaId,
            },
          });

        assert.equal(
          invalidOrder,
          null
        );
      }
    );

    /**
     * ========================================================
     * C02.07
     * ========================================================
     *
     * Organization B não possui relação
     * CustomerOrganization com João.
     *
     * Portanto não pode criar uma OS usando
     * João nem seus equipamentos.
     */

    test(
      'Organization B cannot create a Service Order for Customer belonging only to Organization A',
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
          await createOrder(
            token,
            customerJoaoId,
            notebookJoaoId,
            'Tentativa cross-tenant'
          );

        assert.equal(
          response.statusCode,
          403
        );

        const body =
          response.json();

        assert.equal(
          body.error,
          'Customer does not belong to the current organization'
        );

        /**
         * Nenhuma OS de B deve ter sido criada
         * para João.
         */
        const orderCount =
          await prisma.serviceOrder.count({
            where: {
              organizationId:
                organizationBId,

              customerId:
                customerJoaoId,
            },
          });

        assert.equal(
          orderCount,
          0
        );
      }
    );
  }
);
