import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import { z } from 'zod';
import { ServiceOrderStatus } from '@prisma/client';

import { prisma } from '../../core/database/prisma.js';

import {
  getAuthUser,
} from '../../core/middleware/auth.middleware.js';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  ALLOWED_TRANSITIONS,
  isValidStatusTransition,
} from './service_order_state_machine.js';

const createOrderSchema = z.object({
  customerId: z.string().uuid(),
  equipmentId: z.string().uuid(),
  technicianId: z.string().uuid().optional(),
  problemDescription: z.string().min(1),
});

const updateStatusSchema = z.object({
  newStatus: z.nativeEnum(ServiceOrderStatus),
  notes: z.string().optional(),
});

export async function listServiceOrdersHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser = getAuthUser(request);

  const whereClause =
    authUser.role === 'CUSTOMER'
      ? {
        organizationId: authUser.organizationId,
        customerId: authUser.customerId!,
      }
      : {
        organizationId: authUser.organizationId,
      };

  const orders = await prisma.serviceOrder.findMany({
    where: whereClause,
    include: {
      customer: true,
      equipment: true,
      technician: true,
    },
    orderBy: {
      createdAt: 'desc',
    },
  });

  return reply.send({
    orders,
  });
}

export async function getServiceOrderHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const { id } = request.params as {
    id: string;
  };

  const authUser = getAuthUser(request);

  const order =
    await prisma.serviceOrder.findFirst({
      where: {
        id,
        organizationId: authUser.organizationId,
      },
      include: {
        customer: true,
        equipment: true,
        technician: true,
      },
    });

  if (!order) {
    return reply.status(404).send({
      error: 'Service Order not found',
    });
  }

  if (authUser.role === 'CUSTOMER') {
    if (
      !authUser.customerId ||
      order.customerId !== authUser.customerId
    ) {
      throw new ForbiddenError(
        'Access denied: you can only access your own Service Orders'
      );
    }
  }

  return reply.send({
    order,
  });
}

export async function createServiceOrderHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body = createOrderSchema.parse(
    request.body
  );

  const authUser = getAuthUser(request);

  /**
   * Verifica se o cliente pertence à organização
   * atualmente autenticada.
   */
  const customerOrganization =
    await prisma.customerOrganization.findUnique({
      where: {
        customerId_organizationId: {
          customerId: body.customerId,
          organizationId: authUser.organizationId,
        },
      },
    });

  if (!customerOrganization) {
    throw new ForbiddenError(
      'Customer does not belong to the current organization'
    );
  }

  /**
   * Verifica se o equipamento pertence ao cliente.
   */
  const equipment =
    await prisma.equipment.findFirst({
      where: {
        id: body.equipmentId,
        customerId: body.customerId,
      },
    });

  if (!equipment) {
    throw new ForbiddenError(
      'Equipment does not belong to the specified customer'
    );
  }

  /**
   * Se um técnico foi informado, verifica se ele
   * pertence à mesma organização.
   */
  if (body.technicianId) {
    const technician =
      await prisma.membership.findUnique({
        where: {
          userId_organizationId: {
            userId: body.technicianId,
            organizationId: authUser.organizationId,
          },
        },
      });

    if (
      !technician ||
      !['ADMIN', 'TECHNICIAN'].includes(
        technician.role
      )
    ) {
      throw new ForbiddenError(
        'Technician does not belong to the current organization'
      );
    }
  }

  const order =
    await prisma.serviceOrder.create({
      data: {
        organizationId:
          authUser.organizationId,

        customerId: body.customerId,

        equipmentId: body.equipmentId,

        technicianId:
          body.technicianId,

        problemDescription:
          body.problemDescription,

        status:
          ServiceOrderStatus.DIAGNOSTICO,
      },
    });

  return reply.status(201).send({
    order,
  });
}

export async function updateServiceOrderStatusHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const { id } = request.params as {
    id: string;
  };

  const body = updateStatusSchema.parse(
    request.body
  );

  const authUser = getAuthUser(request);

  const changedById = authUser.sub;

  const order =
    await prisma.serviceOrder.findFirst({
      where: {
        id,
        organizationId: authUser.organizationId,
      },
    });

  if (!order) {
    return reply.status(404).send({
      error: 'Service Order not found',
    });
  }

  if (
    !isValidStatusTransition(
      order.status,
      body.newStatus
    )
  ) {
    return reply.status(409).send({
      error:
        `Invalid status transition from ` +
        `${order.status} to ${body.newStatus}`,

      allowedTransitions:
        ALLOWED_TRANSITIONS[
        order.status
        ] || [],
    });
  }

  const updatedOrder =
    await prisma.$transaction(
      async (tx) => {
        const updated =
          await tx.serviceOrder.update({
            where: {
              id,
            },

            data: {
              status:
                body.newStatus,
            },
          });

        await tx.serviceOrderStatusHistory.create({
          data: {
            serviceOrderId: id,

            previousStatus:
              order.status,

            newStatus:
              body.newStatus,

            changedById,

            notes: body.notes,
          },
        });

        return updated;
      }
    );

  return reply.send({
    order: updatedOrder,
  });
}