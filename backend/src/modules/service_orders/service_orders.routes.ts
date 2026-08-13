import { FastifyInstance } from 'fastify';
import {
  listServiceOrdersHandler,
  getServiceOrderHandler,
  createServiceOrderHandler,
  updateServiceOrderStatusHandler,
} from './service_orders.controller.js';

export async function serviceOrderRoutes(fastify: FastifyInstance) {
  const auth = (fastify as any).authenticate;
  const adminOrTech = (fastify as any).authorize(['ADMIN', 'TECHNICIAN']);

  // P0.2: List is accessible to all roles; CUSTOMER scope is enforced in the controller.
  fastify.get('/', { preValidation: [auth] }, listServiceOrdersHandler);

  // P0.2: GET /:id accessible to all authenticated; ownership check is in the controller.
  fastify.get('/:id', { preValidation: [auth] }, getServiceOrderHandler);

  // Create and status update: ADMIN/TECHNICIAN only.
  fastify.post('/', { preValidation: [auth, adminOrTech] }, createServiceOrderHandler);
  fastify.patch('/:id/status', { preValidation: [auth, adminOrTech] }, updateServiceOrderStatusHandler);
}
