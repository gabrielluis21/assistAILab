import { FastifyInstance } from 'fastify';

import {
  listCustomersHandler,
  createCustomerHandler,
  getCustomerHandler,
} from './customers.controller.js';

export async function customerRoutes(
  fastify: FastifyInstance
) {
  const auth =
    (fastify as any).authenticate;

  const adminOrTech =
    (fastify as any).authorize([
      'ADMIN',
      'TECHNICIAN',
    ]);

  fastify.get(
    '/',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    listCustomersHandler
  );

  fastify.post(
    '/',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    createCustomerHandler
  );

  fastify.get(
    '/:id',
    {
      preValidation: [
        auth,
      ],
    },
    getCustomerHandler
  );
}