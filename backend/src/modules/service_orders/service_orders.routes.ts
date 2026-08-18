import { FastifyInstance } from 'fastify';

import {
  listServiceOrdersHandler,
  getServiceOrderHandler,
  createServiceOrderHandler,
  updateServiceOrderStatusHandler,
} from './service_orders.controller.js';

export async function serviceOrderRoutes(
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
      preValidation: [auth],
    },
    listServiceOrdersHandler
  );

  fastify.get(
    '/:id',
    {
      preValidation: [auth],
    },
    getServiceOrderHandler
  );

  fastify.post(
    '/',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    createServiceOrderHandler
  );

  fastify.patch(
    '/:id/status',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    updateServiceOrderStatusHandler
  );
}