import { FastifyInstance } from 'fastify';
import {
  listPaymentsHandler,
  getPaymentHandler,
  createPaymentHandler,
  updatePaymentStatusHandler,
  getRevenueSummaryHandler,
} from './payments.controller.js';

export async function paymentsRoutes(fastify: FastifyInstance) {
  const auth = (fastify as any).authenticate;
  const adminOrTech = (fastify as any).authorize(['ADMIN', 'TECHNICIAN']);

  // P0.2: Read access open to all authenticated; CUSTOMER scope enforced in controller.
  fastify.get('/', { preValidation: [auth] }, listPaymentsHandler);
  fastify.get('/:id', { preValidation: [auth] }, getPaymentHandler);

  // P0.2: Revenue summary is administrative data — CUSTOMER must not access it.
  fastify.get('/summary', { preValidation: [auth, adminOrTech] }, getRevenueSummaryHandler);

  // Mutations restricted to ADMIN/TECHNICIAN only.
  fastify.post('/', { preValidation: [auth, adminOrTech] }, createPaymentHandler);
  fastify.patch('/:id/status', { preValidation: [auth, adminOrTech] }, updatePaymentStatusHandler);
}
