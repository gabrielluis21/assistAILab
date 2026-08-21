import {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  z,
} from 'zod';

import {
  CustomerEventType,
  EquipmentOwnerType,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  ConflictError,
  ForbiddenError,
  NotFoundError,
} from '../../core/utils/errors.js';

import {
  customerEventService,
} from '../customer_relationship/customer_event.service.js';

import {
  customerProfileService,
} from '../customer_relationship/customer_profile.service.js';

const customerSchema =
  z.object({
    name:
      z.string()
        .trim()
        .min(2)
        .max(120),

    document:
      z.string()
        .trim()
        .min(1)
        .max(50)
        .optional(),

    email:
      z.string()
        .trim()
        .email()
        .max(191)
        .optional(),

    phone:
      z.string()
        .trim()
        .min(1)
        .max(20)
        .optional(),

    address:
      z.string()
        .trim()
        .min(1)
        .max(500)
        .optional(),
  });

/**
 * ============================================================
 * LIST CUSTOMERS
 * ============================================================
 *
 * ADMIN / TECHNICIAN:
 *
 * lista somente Customers vinculados
 * à Organization autenticada.
 */
export async function listCustomersHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  /**
   * Esta operação é organizacional.
   *
   * CUSTOMER não possui organizationId
   * no JWT global.
   */
  const organizationId =
    requireOrganizationId(
      authUser
    );

  const customers =
    await prisma.customer.findMany({
      where: {
        organizations: {
          some: {
            organizationId,
          },
        },
      },

      include: {
        organizations: {
          where: {
            organizationId,
          },

          include: {
            profile:
              true,
          },
        },
      },

      orderBy: {
        name:
          'asc',
      },
    });

  return reply.send({
    customers,
  });
}

/**
 * ============================================================
 * CREATE CUSTOMER
 * ============================================================
 *
 * ADMIN / TECHNICIAN:
 *
 * cria a identidade global Customer
 * e imediatamente cria o vínculo
 * CustomerOrganization com o tenant atual.
 */
export async function createCustomerHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body =
    customerSchema.parse(
      request.body
    );

  const authUser =
    getAuthUser(
      request
    );

  /**
   * Criação feita pela assistência sempre
   * exige contexto organizacional.
   */
  const organizationId =
    requireOrganizationId(
      authUser
    );

  /**
   * Customer.document é globalmente único.
   *
   * IMPORTANTE:
   * não vinculamos automaticamente um Customer
   * pertencente a outra Organization apenas
   * porque alguém informou o mesmo documento.
   *
   * Esse vínculo entre organizações deverá
   * passar por onboarding verificado.
   */
  if (
    body.document
  ) {
    const existingCustomer =
      await prisma.customer.findUnique({
        where: {
          document:
            body.document,
        },

        include: {
          organizations:
            true,
        },
      });

    if (
      existingCustomer
    ) {
      const currentRelationship =
        existingCustomer
          .organizations
          .find(
            (
              relationship
            ) =>
              relationship
                .organizationId ===
              organizationId
          );

      if (
        currentRelationship
      ) {
        throw new ConflictError(
          'Customer already belongs to the current organization'
        );
      }

      throw new ConflictError(
        'A customer with this document already exists. Linking an existing customer to another organization requires verified customer onboarding.'
      );
    }
  }

  const result =
    await prisma.$transaction(
      async (
        tx
      ) => {
        /**
         * 1. Identidade global do Customer.
         */
        const customer =
          await tx.customer.create({
            data: {
              name:
                body.name,

              document:
                body.document,

              email:
                body.email,

              phone:
                body.phone,

              address:
                body.address,
            },
          });

        /**
         * 2. Relacionamento com o tenant.
         */
        const relationship =
          await tx
            .customerOrganization
            .create({
              data: {
                customerId:
                  customer.id,

                organizationId,

                status:
                  'ACTIVE',
              },
            });

        /**
         * 3. Timeline do Customer Relationship.
         */
        await customerEventService.create(
          {
            customerId:
              customer.id,

            organizationId,

            type:
              CustomerEventType
                .CUSTOMER_REGISTERED,

            title:
              'Cliente cadastrado',

            description:
              'O cliente foi cadastrado e vinculado à organização.',

            metadata: {
              relationshipId:
                relationship.id,

              createdById:
                authUser.sub,
            },
          },

          tx
        );

        /**
         * 4. Cria/recalcula o perfil CRM inicial.
         *
         * Cliente novo:
         *
         * totalServiceOrders = 0
         * riskScore = 0
         * riskLevel = LOW
         */
        const profile =
          await customerProfileService
            .recalculate(
              customer.id,
              organizationId,
              tx
            );

        return {
          customer,
          relationship,
          profile,
        };
      }
    );

  return reply
    .status(201)
    .send(
      result
    );
}

/**
 * ============================================================
 * GET CUSTOMER
 * ============================================================
 *
 * CUSTOMER:
 *
 * acessa somente a própria identidade global.
 *
 * ADMIN / TECHNICIAN:
 *
 * acessa o Customer somente dentro
 * da Organization autenticada.
 */
export async function getCustomerHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      request
    );

  /**
   * ==========================================================
   * CUSTOMER GLOBAL
   * ==========================================================
   */
  if (
    authUser.role ===
    'CUSTOMER'
  ) {
    if (
      !authUser.customerId ||
      authUser.customerId !==
      id
    ) {
      throw new ForbiddenError(
        'Access denied: you can only access your own Customer record'
      );
    }

    const customer =
      await prisma.customer.findUnique({
        where: {
          id:
            authUser.customerId,
        },

        include: {
          /**
           * O Customer pode possuir relações
           * com mais de uma assistência.
           *
           * Cada profile continua pertencendo
           * ao respectivo CustomerOrganization.
           */
          organizations: {
            include: {
              organization: {
                select: {
                  id:
                    true,

                  name:
                    true,
                },
              },

              profile:
                true,
            },
          },

          /**
           * Equipment atualmente pertencente
           * ao próprio Customer.
           *
           * Equipment transferido para Organization
           * passa a possuir customerId = null.
           */
          equipments: {
            where: {
              ownerType:
                EquipmentOwnerType
                  .CUSTOMER,
            },

            orderBy: {
              updatedAt:
                'desc',
            },
          },
        },
      });

    if (
      !customer
    ) {
      throw new NotFoundError(
        'Customer not found'
      );
    }

    return reply.send({
      customer,
    });
  }

  /**
   * ==========================================================
   * ADMIN / TECHNICIAN
   * ==========================================================
   *
   * Neste ramo organizationId obrigatoriamente
   * precisa existir.
   */
  const organizationId =
    requireOrganizationId(
      authUser
    );

  const customer =
    await prisma.customer.findFirst({
      where: {
        id,

        organizations: {
          some: {
            organizationId,
          },
        },
      },

      include: {
        /**
         * Retorna somente o relacionamento
         * com a Organization autenticada.
         */
        organizations: {
          where: {
            organizationId,
          },

          include: {
            profile:
              true,
          },
        },

        /**
         * A assistência somente enxerga
         * Equipment CUSTOMER que já tenha
         * aparecido em uma OS própria.
         */
        equipments: {
          where: {
            ownerType:
              EquipmentOwnerType
                .CUSTOMER,

            serviceOrders: {
              some: {
                organizationId,
              },
            },
          },

          orderBy: {
            updatedAt:
              'desc',
          },
        },
      },
    });

  if (
    !customer
  ) {
    throw new NotFoundError(
      'Customer not found in the current organization'
    );
  }

  return reply.send({
    customer,
  });
}