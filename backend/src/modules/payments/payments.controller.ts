import { FastifyRequest, FastifyReply } from 'fastify';
import { createPaymentSchema, updatePaymentStatusSchema } from './payments.schema.js';
import { PaymentsService } from './payments.service.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ForbiddenError } from '../../core/utils/errors.js';

const svc = new PaymentsService();

// P0.2: CUSTOMER receives only their own payments; ADMIN/TECH receive all.
export async function listPaymentsHandler(req: FastifyRequest, reply: FastifyReply) {
  const authUser = getAuthUser(req);

  if (authUser.role === 'CUSTOMER') {
    if (!authUser.customerId) {
      throw new ForbiddenError('Access denied: no customer identity associated with this account');
    }
    return reply.send(await svc.listAll(undefined, authUser.customerId));
  }

  const { serviceOrderId, customerId } = req.query as {
    serviceOrderId?: string;
    customerId?: string;
  };
  return reply.send(await svc.listAll(serviceOrderId, customerId));
}

// P0.2: CUSTOMER can only access their own payment record.
export async function getPaymentHandler(req: FastifyRequest, reply: FastifyReply) {
  const { id } = req.params as { id: string };
  const authUser = getAuthUser(req);

  const payment = await svc.findById(id);

  if (authUser.role === 'CUSTOMER') {
    if (!authUser.customerId || payment.customerId !== authUser.customerId) {
      throw new ForbiddenError('Access denied: you can only access your own payment records');
    }
  }

  return reply.send(payment);
}

// ADMIN / TECHNICIAN only
export async function createPaymentHandler(req: FastifyRequest, reply: FastifyReply) {
  const operationId = (req.headers['x-operation-id'] as string) ?? '';
  const body = createPaymentSchema.parse(req.body);
  return reply.status(201).send(await svc.create(body, operationId));
}

// ADMIN / TECHNICIAN only
export async function updatePaymentStatusHandler(req: FastifyRequest, reply: FastifyReply) {
  const { id } = req.params as { id: string };
  const body = updatePaymentStatusSchema.parse(req.body);
  return reply.send(await svc.updateStatus(id, body));
}

// ADMIN / TECHNICIAN only — revenue summary is administrative data
export async function getRevenueSummaryHandler(req: FastifyRequest, reply: FastifyReply) {
  return reply.send(await svc.getRevenueSummary());
}
