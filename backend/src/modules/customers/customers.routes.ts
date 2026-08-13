import { FastifyInstance } from 'fastify';
import { listCustomersHandler, createCustomerHandler, getCustomerHandler } from './customers.controller.js';

export async function customerRoutes(fastify: FastifyInstance) {
  const auth = (fastify as any).authenticate;
  const adminOrTech = (fastify as any).authorize(['ADMIN', 'TECHNICIAN']);

  // P0.2: List and create are restricted to ADMIN/TECHNICIAN.
  // CUSTOMER role must NOT be able to enumerate all customers.
  fastify.get('/', { preValidation: [auth, adminOrTech] }, listCustomersHandler);
  fastify.post('/', { preValidation: [auth, adminOrTech] }, createCustomerHandler);

  // P0.2: Any authenticated user can call GET /:id, but the controller enforces
  // that a CUSTOMER can only retrieve their own record.
  fastify.get('/:id', { preValidation: [auth] }, getCustomerHandler);
}
