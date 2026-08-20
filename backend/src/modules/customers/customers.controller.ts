import {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import { z } from 'zod';

import {
  CustomerEventType,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  getAuthUser,
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

const customerSchema = z.object({
  name: z
    .string()
    .trim()
    .min(2)
    .max(120),

  document: z
    .string()
    .trim()
    .min(1)
    .max(50)
    .optional(),

  email: z
    .string()
    .trim()
    .email()
    .max(191)
    .optional(),

  phone: z
    .string()
    .trim()
    .min(1)
    .max(20)
    .optional(),

  address: z
    .string()
    .trim()
    .min(1)
    .max(500)
    .optional(),
});

/**
 * Lista somente clientes vinculados
 * à organização autenticada.
 *
 * ADMIN / TECHNICIAN.
 */
export async function listCustomersHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser =
    getAuthUser(request);

  const customers =
    await prisma.customer.findMany({
      where: {
        organizations: {
          some: {
            organizationId:
              authUser.organizationId,
          },
        },
      },

      include: {
        organizations: {
          where: {
            organizationId:
              authUser.organizationId,
          },

          include: {
            profile: true,
          },
        },
      },

      orderBy: {
        name: 'asc',
      },
    });

  return reply.send({
    customers,
  });
}

/**
 * Cria um cliente e imediatamente
 * cria seu vínculo com a organização.
 *
 * ADMIN / TECHNICIAN.
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
    getAuthUser(request);

  /**
   * Customer.document é globalmente único.
   *
   * IMPORTANTE:
   * não vinculamos automaticamente um Customer
   * pertencente a outra Organization apenas
   * porque alguém informou o mesmo documento.
   *
   * Esse vínculo entre organizações deverá
   * futuramente passar pelo onboarding/
   * AccessGrant do cliente.
   */
  if (body.document) {
    const existingCustomer =
      await prisma.customer.findUnique({
        where: {
          document:
            body.document,
        },

        include: {
          organizations: true,
        },
      });

    if (existingCustomer) {
      const currentRelationship =
        existingCustomer.organizations.find(
          (relationship) =>
            relationship.organizationId ===
            authUser.organizationId
        );

      if (currentRelationship) {
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
      async (tx) => {
        /**
         * 1. Identidade do cliente.
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
          await tx.customerOrganization.create({
            data: {
              customerId:
                customer.id,

              organizationId:
                authUser.organizationId,

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

            organizationId:
              authUser.organizationId,

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
         * totalServiceOrders = 0
         * riskScore = 0
         * riskLevel = LOW
         */
        const profile =
          await customerProfileService.recalculate(
            customer.id,
            authUser.organizationId,
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
    .send(result);
}

/**
 * Recupera cliente somente se ele fizer
 * parte da organização autenticada.
 */
export async function getCustomerHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const { id } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(request);

  /**
   * CUSTOMER só pode pedir a própria identidade.
   */
  if (
    authUser.role === 'CUSTOMER' &&
    (
      !authUser.customerId ||
      authUser.customerId !== id
    )
  ) {
    throw new ForbiddenError(
      'Access denied: you can only access your own Customer record'
    );
  }

  /**
   * Mesmo ADMIN/TECHNICIAN precisa estar
   * no tenant ao qual o Customer pertence.
   */
  const customer =
    await prisma.customer.findFirst({
      where: {
        id,

        organizations: {
          some: {
            organizationId:
              authUser.organizationId,
          },
        },
      },

      include: {
        organizations: {
          where: {
            organizationId:
              authUser.organizationId,
          },

          include: {
            profile: true,
          },
        },

        equipments: {
          where: {
            serviceOrders: {
              some: {
                organizationId:
                  authUser.organizationId,
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

  if (!customer) {
    throw new NotFoundError(
      'Customer not found in the current organization'
    );
  }

  return reply.send({
    customer,
  });
}