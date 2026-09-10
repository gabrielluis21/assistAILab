import type {
  FastifyInstance,
} from 'fastify';

import {
  cancelReceivableHandler,
  rescheduleReceivableHandler,
} from './receivables.controller.js';

export async function receivablesRoutes(
  fastify:
    FastifyInstance
) {
  const auth =
    (fastify as any)
      .authenticate;

  const adminOnly =
    (fastify as any)
      .authorize([
        'ADMIN',
      ]);

  fastify.post(
    '/:id/reschedule',
    {
      preValidation: [
        auth,
        adminOnly,
      ],
    },
    rescheduleReceivableHandler
  );

  fastify.post(
    '/:id/cancel',
    {
      preValidation: [
        auth,
        adminOnly,
      ],
    },
    cancelReceivableHandler
  );
}
