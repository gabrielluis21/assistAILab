import {
  after,
  before,
  describe,
  test,
} from 'node:test';

import assert from 'node:assert/strict';

import {
  randomUUID,
} from 'node:crypto';

import bcrypt from 'bcrypt';

import type {
  FastifyInstance,
} from 'fastify';

import {
  CustomerOrganizationStatus,
  EquipmentOwnerType,
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
  isValidStatusTransition,
} from './service_order_state_machine.js';

/**
 * ============================================================
 * SERVICE ORDER STATE MACHINE
 * ============================================================
 *
 * Cobertura transversal utilizada principalmente por:
 *
 * C05 — cancelamento de OS
 * C07 — fluxo completo de OS
 *
 * Estes testes já existiam e DEVEM permanecer.
 */
describe(
  'Service Order State Machine Hardening',
  () => {
    test(
      'Valid state transitions pass',
      () => {
        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.DRAFT,
            ServiceOrderStatus.DIAGNOSTICO
          ),
          true
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.DIAGNOSTICO,
            ServiceOrderStatus.AGUARDANDO_APROVACAO
          ),
          true
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.AGUARDANDO_APROVACAO,
            ServiceOrderStatus.EM_EXECUCAO
          ),
          true
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.EM_EXECUCAO,
            ServiceOrderStatus.PRONTO
          ),
          true
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.PRONTO,
            ServiceOrderStatus.ENTREGUE
          ),
          true
        );
      }
    );

    test(
      'Cancellation from valid states is allowed',
      () => {
        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.DRAFT,
            ServiceOrderStatus.CANCELADO
          ),
          true
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.DIAGNOSTICO,
            ServiceOrderStatus.CANCELADO
          ),
          true
        );
      }
    );

    test(
      'Invalid backward or skipped transitions are rejected',
      () => {
        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.ENTREGUE,
            ServiceOrderStatus.DIAGNOSTICO
          ),
          false
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.CANCELADO,
            ServiceOrderStatus.EM_EXECUCAO
          ),
          false
        );

        assert.equal(
          isValidStatusTransition(
            ServiceOrderStatus.DRAFT,
            ServiceOrderStatus.ENTREGUE
          ),
          false
        );
      }
    );
  }
);

/**
 * ============================================================
 * C2 — CUSTOMER + EQUIPMENT + SERVICE ORDER
 * ============================================================
 *
 * Cenário real:
 *
 * 1. Cliente chega à assistência.
 * 2. Customer já possui pré-cadastro.
 * 3. Técnico registra problema relatado.
 * 4. Técnico informa os dados do equipamento.
 * 5. Equipment + ServiceOrder são criados no mesmo fluxo.
 *
 * Atendimento futuro:
 *
 * - Equipment já conhecido pela Organization
 *   pode ser reutilizado através de equipmentId.
 *
 * Primeiro atendimento:
 *
 * - Equipment é enviado junto da nova OS.
 *
 * Regras:
 *
 * C02.01 CustomerOrganization deve estar ACTIVE.
 * C02.02 Equipment deve pertencer ao Customer.
 * C02.03 OS mantém Organization + Customer + Equipment.
 * C02.04 CustomerOrganization não libera todos os Equipment.
 * C02.05 Organization conhece Equipment através de sua OS.
 * C02.06 CRM não recebe lifecycle events indevidos.
 * C02.07 Isolamento entre Organizations.
 * C02.08 Mesmo Customer pode ter Notebook + Celular.
 */
describe(
  'C2 - Customer Equipment & Service Order Integration',
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
     * ========================================================
     * HISTORICAL SERVICE ORDERS
     * ========================================================
     *
     * Essas OS representam equipamentos que a
     * Organization A já conhece.
     */

    const knownNotebookJoaoOrderId =
      randomUUID();

    const knownCelularJoaoOrderId =
      randomUUID();

    const knownNotebookMariaOrderId =
      randomUUID();

    /**
     * ========================================================
     * RUNTIME CREATED IDS
     * ========================================================
     *
     * Tudo criado através da API será registrado
     * aqui para cleanup.
     */

    const createdOrderIds:
      string[] = [];

    const createdEquipmentIds:
      string[] = [];

    /**
     * ========================================================
     * PAYLOAD TYPES
     * ========================================================
     */

    type NewEquipmentPayload = {
      type: string;
      brand: string;
      model: string;
      serialNumber?: string;
      notes?: string;
    };

    type CreateOrderPayload = {
      customerId: string;
      technicianId?: string;
      problemDescription: string;

      equipmentId?: string;

      equipment?:
      NewEquipmentPayload;
    };

    /**
     * ========================================================
     * HELPERS
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

    async function createOrder(
      token: string,
      payload:
        CreateOrderPayload
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

        payload,
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
         *
         * João é cliente de A e B.
         *
         * Isso é proposital.
         *
         * Mesmo B conhecendo João,
         * B NÃO deverá enxergar automaticamente
         * equipamentos atendidos somente por A.
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
              customerJoaoId,

            organizationId:
              organizationBId,

            status:
              CustomerOrganizationStatus.ACTIVE,
          },
        });

        /**
         * Maria pertence somente à A.
         */
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
         * Carlos pertence à A, mas está BLOCKED.
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
         * ====================================================
         * HISTÓRICO DA ORGANIZATION A
         * ====================================================
         *
         * Estes Equipment agora são conhecidos
         * pela Organization A através de OS.
         */

        await prisma.serviceOrder.create({
          data: {
            id:
              knownNotebookJoaoOrderId,

            organizationId:
              organizationAId,

            customerId:
              customerJoaoId,

            equipmentId:
              notebookJoaoId,

            problemDescription:
              'Historical C2 notebook order',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id:
              knownCelularJoaoOrderId,

            organizationId:
              organizationAId,

            customerId:
              customerJoaoId,

            equipmentId:
              celularJoaoId,

            problemDescription:
              'Historical C2 cellphone order',
          },
        });

        await prisma.serviceOrder.create({
          data: {
            id:
              knownNotebookMariaOrderId,

            organizationId:
              organizationAId,

            customerId:
              customerMariaId,

            equipmentId:
              notebookMariaId,

            problemDescription:
              'Historical C2 Maria order',
          },
        });

        /**
         * Fastify é criado somente depois
         * das fixtures.
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
         * Primeiro removemos ServiceOrders.
         */

        await prisma.serviceOrder.deleteMany({
          where: {
            id: {
              in: [
                ...createdOrderIds,

                knownNotebookJoaoOrderId,
                knownCelularJoaoOrderId,
                knownNotebookMariaOrderId,
              ],
            },
          },
        });

        /**
         * Depois os Equipments.
         *
         * Inclui Equipments criados dinamicamente
         * pelo novo fluxo da OS.
         */

        await prisma.equipment.deleteMany({
          where: {
            id: {
              in: [
                notebookJoaoId,
                celularJoaoId,
                notebookMariaId,
                notebookBlockedId,

                ...createdEquipmentIds,
              ],
            },
          },
        });

        /**
         * CustomerOrganization.
         */

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

        /**
         * Customers.
         */

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

        /**
         * Memberships.
         */

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

        /**
         * Users.
         */

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

        /**
         * Restaura ambiente.
         */

        if (
          oldJwtSecret
        ) {
          process.env.JWT_SECRET =
            oldJwtSecret;
        } else {
          delete process.env.JWT_SECRET;
        }
      }
    );

    /**
     * ========================================================
     * C02.01 + C02.03 + C02.08
     * ========================================================
     *
     * João possui Notebook e Celular previamente
     * conhecidos pela Organization A.
     *
     * A Organization pode abrir novas OS para ambos.
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
            {
              customerId:
                customerJoaoId,

              equipmentId:
                notebookJoaoId,

              problemDescription:
                'Notebook não inicializa',
            }
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
            {
              customerId:
                customerJoaoId,

              equipmentId:
                celularJoaoId,

              problemDescription:
                'Celular não carrega',
            }
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
         * Contraprova no banco.
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
     * CustomerOrganization BLOCKED não pode abrir OS.
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
            {
              customerId:
                customerBlockedId,

              equipmentId:
                notebookBlockedId,

              problemDescription:
                'Tentativa de OS para cliente bloqueado',
            }
          );

        assert.equal(
          response.statusCode,
          403
        );

        assert.equal(
          response.json().error,
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
     * Customer = João
     * Equipment = Maria
     *
     * Deve ser rejeitado.
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
            {
              customerId:
                customerJoaoId,

              equipmentId:
                notebookMariaId,

              problemDescription:
                'Tentativa de usar equipamento de outro cliente',
            }
          );

        assert.equal(
          response.statusCode,
          403
        );

        assert.equal(
          response.json().error,
          'Equipment is not available to the current organization'
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
     * Maria pertence somente à Organization A.
     *
     * B não pode abrir OS para ela.
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
            {
              customerId:
                customerMariaId,

              equipmentId:
                notebookMariaId,

              problemDescription:
                'Tentativa cross-tenant',
            }
          );

        assert.equal(
          response.statusCode,
          403
        );

        assert.equal(
          response.json().error,
          'Customer does not belong to the current organization'
        );

        const orderCount =
          await prisma.serviceOrder.count({
            where: {
              organizationId:
                organizationBId,

              customerId:
                customerMariaId,
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
     * C02.04 + C02.05
     * ========================================================
     *
     * Cenário:
     *
     * João possui relacionamento ACTIVE com A e B.
     *
     * Notebook João foi atendido somente por A.
     *
     * Logo:
     *
     * A pode conhecer o Notebook.
     * B NÃO pode conhecê-lo apenas porque conhece João.
     *
     * Quando João leva um novo aparelho para B:
     *
     * Equipment + OS nascem juntos.
     *
     * Depois disso B passa a conhecer aquele Equipment.
     */
    test(
      'CustomerOrganization alone does not grant Equipment access and first service creates Equipment with the Service Order',
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

        /**
         * ----------------------------------------------------
         * LIST
         * ----------------------------------------------------
         *
         * B conhece João como Customer,
         * mas não deve receber o Notebook
         * atendido somente por A.
         */

        const listBeforeResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment?customerId=${customerJoaoId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          listBeforeResponse.statusCode,
          200
        );

        const listBefore =
          listBeforeResponse.json();

        assert.ok(
          Array.isArray(
            listBefore
          )
        );

        assert.equal(
          listBefore.some(
            (
              equipment:
                { id: string }
            ) =>
              equipment.id ===
              notebookJoaoId
          ),
          false
        );

        /**
         * ----------------------------------------------------
         * GET DIRETO
         * ----------------------------------------------------
         */

        const hiddenResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment/${notebookJoaoId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          hiddenResponse.statusCode,
          404
        );

        /**
         * ----------------------------------------------------
         * TENTATIVA DE REUTILIZAR UUID
         * ----------------------------------------------------
         *
         * Mesmo que B conheça o UUID,
         * não pode usar Equipment ainda
         * desconhecido pela Organization.
         */

        const reuseResponse =
          await createOrder(
            token,
            {
              customerId:
                customerJoaoId,

              equipmentId:
                notebookJoaoId,

              problemDescription:
                'Tentativa de reutilizar Equipment não conhecido',
            }
          );

        assert.equal(
          reuseResponse.statusCode,
          403
        );

        assert.equal(
          reuseResponse.json().error,
          'Equipment is not available to the current organization'
        );

        /**
         * ----------------------------------------------------
         * PRIMEIRO ATENDIMENTO REAL
         * ----------------------------------------------------
         *
         * João chega à B com um Tablet.
         *
         * Técnico informa dados do equipamento
         * junto da OS.
         */

        const firstOrderResponse =
          await createOrder(
            token,
            {
              customerId:
                customerJoaoId,

              equipment: {
                type:
                  'TABLET',

                brand:
                  'Samsung',

                model:
                  'Galaxy Tab C2',

                serialNumber:
                  `C2-TAB-${runId}`,

                notes:
                  'Tela trincada no canto superior',
              },

              problemDescription:
                'Tela quebrada e touch falhando',
            }
          );

        assert.equal(
          firstOrderResponse.statusCode,
          201
        );

        const {
          order,
        } =
          firstOrderResponse.json();

        createdOrderIds.push(
          order.id
        );

        createdEquipmentIds.push(
          order.equipmentId
        );

        /**
         * ----------------------------------------------------
         * SERVICE ORDER
         * ----------------------------------------------------
         */

        assert.equal(
          order.organizationId,
          organizationBId
        );

        assert.equal(
          order.customerId,
          customerJoaoId
        );

        assert.equal(
          order.status,
          ServiceOrderStatus.DIAGNOSTICO
        );

        /**
         * ----------------------------------------------------
         * EQUIPMENT PERSISTIDO
         * ----------------------------------------------------
         */

        const equipment =
          await prisma.equipment.findUnique({
            where: {
              id:
                order.equipmentId,
            },
          });

        assert.ok(
          equipment
        );

        assert.equal(
          equipment.customerId,
          customerJoaoId
        );

        assert.equal(
          equipment.ownerType,
          EquipmentOwnerType.CUSTOMER
        );

        /**
         * Equipment continua pertencendo
         * ao Customer.
         */
        assert.equal(
          equipment.organizationId,
          null
        );

        assert.equal(
          equipment.organizationPurpose,
          null
        );

        assert.equal(
          equipment.type,
          'TABLET'
        );

        assert.equal(
          equipment.brand,
          'Samsung'
        );

        assert.equal(
          equipment.model,
          'Galaxy Tab C2'
        );

        /**
         * ----------------------------------------------------
         * B AGORA CONHECE O EQUIPMENT
         * ----------------------------------------------------
         */

        const visibleResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment/${order.equipmentId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          visibleResponse.statusCode,
          200
        );

        const visibleEquipment =
          visibleResponse.json();

        assert.equal(
          visibleEquipment.id,
          order.equipmentId
        );

        /**
         * A resposta só pode trazer
         * ServiceOrders da Organization B.
         */

        assert.ok(
          Array.isArray(
            visibleEquipment.serviceOrders
          )
        );

        assert.ok(
          visibleEquipment
            .serviceOrders
            .every(
              (
                serviceOrder:
                  { id: string }
              ) =>
                serviceOrder.id !==
                knownNotebookJoaoOrderId
            )
        );

        /**
         * ----------------------------------------------------
         * LIST DEPOIS DA OS
         * ----------------------------------------------------
         */

        const listAfterResponse =
          await app.inject({
            method:
              'GET',

            url:
              `/api/v1/equipment?customerId=${customerJoaoId}`,

            headers: {
              authorization:
                `Bearer ${token}`,
            },
          });

        assert.equal(
          listAfterResponse.statusCode,
          200
        );

        const listAfter =
          listAfterResponse.json();

        /**
         * Novo Tablet agora aparece.
         */
        assert.equal(
          listAfter.some(
            (
              item:
                { id: string }
            ) =>
              item.id ===
              order.equipmentId
          ),
          true
        );

        /**
         * Notebook atendido somente
         * por A continua oculto.
         */
        assert.equal(
          listAfter.some(
            (
              item:
                { id: string }
            ) =>
              item.id ===
              notebookJoaoId
          ),
          false
        );
      }
    );

    /**
     * ========================================================
     * C02.04 / DEFESA DE FLUXO
     * ========================================================
     *
     * ADMIN / TECH não pode criar Equipment
     * CUSTOMER isoladamente.
     *
     * Primeiro cadastro do equipamento deve
     * acontecer junto da ServiceOrder.
     *
     * Futuramente Equipment ORGANIZATION será
     * tratado pelo fluxo EquipmentAcquisition.
     */
    test(
      'Internal staff cannot register standalone Customer Equipment outside Service Order flow',
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

        const standaloneEquipmentId =
          randomUUID();

        const response =
          await app.inject({
            method:
              'PUT',

            url:
              '/api/v1/equipment',

            headers: {
              authorization:
                `Bearer ${token}`,
            },

            payload: {
              id:
                standaloneEquipmentId,

              customerId:
                customerJoaoId,

              type:
                'NOTEBOOK',

              brand:
                'Dell',

              model:
                'Standalone C2',
            },
          });

        assert.equal(
          response.statusCode,
          403
        );

        assert.equal(
          response.json().error,
          'Equipment must be registered through a Service Order or an approved acquisition flow'
        );

        /**
         * Confirma que nenhum Equipment
         * órfão foi criado.
         */

        const equipment =
          await prisma.equipment.findUnique({
            where: {
              id:
                standaloneEquipmentId,
            },
          });

        assert.equal(
          equipment,
          null
        );
      }
    );
  }
);