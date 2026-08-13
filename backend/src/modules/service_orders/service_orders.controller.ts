import { FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { ServiceOrderStatus } from '@prisma/client';
import { prisma } from '../../core/database/prisma.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ForbiddenError } from '../../core/utils/errors.js';

import { ALLOWED_TRANSITIONS, isValidStatusTransition } from './service_order_state_machine.js';

const createOrderSchema = z.object({
  customerId: z.string().uuid(),
  equipmentId: z.string().uuid(),
  technicianId: z.string().uuid().optional(),
  problemDescription: z.string().min(1),
});

// P0.4: changedById removed — identity must come from the authenticated JWT (request.user.sub).
// Accepting changedById from the client would allow forging audit history.
const updateStatusSchema = z.object({
  newStatus: z.nativeEnum(ServiceOrderStatus),
  notes: z.string().optional(),
});

// P0.2: CUSTOMER role receives only their own orders; ADMIN/TECH receive all.
export async function listServiceOrdersHandler(request: FastifyRequest, reply: FastifyReply) {
  const authUser = getAuthUser(request);

  const whereClause =
    authUser.role === 'CUSTOMER'
      ? { customerId: authUser.customerId! }
      : {};

  const orders = await prisma.serviceOrder.findMany({
    where: whereClause,
    include: { customer: true, equipment: true, technician: true },
    orderBy: { createdAt: 'desc' },
  });
  return reply.send({ orders });
}

// P0.2: GET /:id — CUSTOMER can only access their own service order.
export async function getServiceOrderHandler(request: FastifyRequest, reply: FastifyReply) {
  const { id } = request.params as { id: string };
  const authUser = getAuthUser(request);

  const order = await prisma.serviceOrder.findUnique({
    where: { id },
    include: { customer: true, equipment: true, technician: true },
  });

  if (!order) {
    return reply.status(404).send({ error: 'Service Order not found' });
  }

  // P0.2: CUSTOMER must only see orders belonging to their own customerId.
  if (authUser.role === 'CUSTOMER') {
    if (!authUser.customerId || order.customerId !== authUser.customerId) {
      throw new ForbiddenError('Access denied: you can only access your own Service Orders');
    }
  }

  return reply.send({ order });
}

// ADMIN / TECHNICIAN only
export async function createServiceOrderHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = createOrderSchema.parse(request.body);
  const order = await prisma.serviceOrder.create({
    data: {
      customerId: body.customerId,
      equipmentId: body.equipmentId,
      technicianId: body.technicianId,
      problemDescription: body.problemDescription,
      status: ServiceOrderStatus.DIAGNOSTICO,
    },
  });
  return reply.status(201).send({ order });
}

// ADMIN / TECHNICIAN only
export async function updateServiceOrderStatusHandler(request: FastifyRequest, reply: FastifyReply) {
  const { id } = request.params as { id: string };
  const body = updateStatusSchema.parse(request.body);

  // P0.4: changedById is derived from the authenticated user — never from client payload.
  const authUser = getAuthUser(request);
  const changedById = authUser.sub;

  const order = await prisma.serviceOrder.findUnique({ where: { id } });
  if (!order) {
    return reply.status(404).send({ error: 'Service Order not found' });
  }

  if (!isValidStatusTransition(order.status, body.newStatus)) {
    return reply.status(409).send({
      error: `Invalid status transition from ${order.status} to ${body.newStatus}`,
      allowedTransitions: ALLOWED_TRANSITIONS[order.status] || [],
    });
  }

  const updatedOrder = await prisma.$transaction(async (tx) => {
    const updated = await tx.serviceOrder.update({
      where: { id },
      data: { status: body.newStatus },
    });

    await tx.serviceOrderStatusHistory.create({
      data: {
        serviceOrderId: id,
        previousStatus: order.status,
        newStatus: body.newStatus,
        changedById, // P0.4: Always set from authenticated user, never from client body
        notes: body.notes,
      },
    });

    return updated;
  });

  return reply.send({ order: updatedOrder });
}
