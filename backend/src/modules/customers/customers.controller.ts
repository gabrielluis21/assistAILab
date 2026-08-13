import { FastifyRequest, FastifyReply } from 'fastify';
import { z } from 'zod';
import { prisma } from '../../core/database/prisma.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ForbiddenError } from '../../core/utils/errors.js';

const customerSchema = z.object({
  name: z.string().min(1),
  document: z.string().optional(),
  email: z.string().email().optional(),
  phone: z.string().optional(),
  address: z.string().optional(),
});

// ADMIN / TECHNICIAN only — CUSTOMER role must not list all customers
export async function listCustomersHandler(request: FastifyRequest, reply: FastifyReply) {
  const customers = await prisma.customer.findMany({
    orderBy: { name: 'asc' },
  });
  return reply.send({ customers });
}

// ADMIN / TECHNICIAN only
export async function createCustomerHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = customerSchema.parse(request.body);
  const customer = await prisma.customer.create({
    data: body,
  });
  return reply.status(201).send({ customer });
}

// All authenticated roles — CUSTOMER may only access their own Customer record
export async function getCustomerHandler(request: FastifyRequest, reply: FastifyReply) {
  const { id } = request.params as { id: string };
  const authUser = getAuthUser(request);

  // P0.2: Resource authorization — CUSTOMER can only read their own Customer record.
  // We return 403 (not 404) to make the access denial explicit.
  if (authUser.role === 'CUSTOMER') {
    if (!authUser.customerId || authUser.customerId !== id) {
      throw new ForbiddenError('Access denied: you can only access your own Customer record');
    }
  }

  const customer = await prisma.customer.findUnique({ where: { id } });
  if (!customer) {
    return reply.status(404).send({ error: 'Customer not found' });
  }
  return reply.send({ customer });
}
