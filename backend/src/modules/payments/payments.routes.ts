import type {
  FastifyInstance,
} from 'fastify';

import {
  createPaymentHandler,
  getPaymentHandler,
  getRevenueSummaryHandler,
  listPaymentsHandler,
  updatePaymentStatusHandler,
} from './payments.controller.js';

export async function paymentsRoutes(
  fastify:
    FastifyInstance
) {
  const auth =
    (fastify as any)
      .authenticate;

  const staff =
    (fastify as any)
      .authorize([
        'ADMIN',
        'TECHNICIAN',
      ]);

  const admin =
    (fastify as any)
      .authorize([
        'ADMIN',
      ]);

  /**
   * Static route before /:id.
   */
  fastify.get(
    '/summary',
    {
      preValidation: [
        auth,
        admin,
      ],
    },
    getRevenueSummaryHandler
  );

  fastify.get(
    '/',
    {
      preValidation: [
        auth,
        staff,
      ],
    },
    listPaymentsHandler
  );

  fastify.get(
    '/:id',
    {
      preValidation: [
        auth,
        staff,
      ],
    },
    getPaymentHandler
  );

  fastify.post(
    '/',
    {
      preValidation: [
        auth,
        staff,
      ],
    },
    createPaymentHandler
  );

  fastify.patch(
    '/:id/status',
    {
      preValidation: [
        auth,
        admin,
      ],
    },
    updatePaymentStatusHandler
  );
}
