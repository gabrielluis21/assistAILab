import {
  FastifyInstance,
} from 'fastify';

import {
  registerHandler,
  loginHandler,
  meHandler,
  createCustomerOnboardingGrantHandler,
  claimCustomerOnboardingHandler,
} from './auth.controller.js';

export async function authRoutes(
  fastify: FastifyInstance
) {
  fastify.post(
    '/register',
    registerHandler
  );

  fastify.post(
    '/login',
    loginHandler
  );

  /**
   * CUSTOMER recebe esse token
   * por QR/link da assistência.
   */
  fastify.post(
    '/customer-onboarding/claim',
    claimCustomerOnboardingHandler
  );

  /**
   * Somente equipe interna gera
   * CUSTOMER_ONBOARDING.
   */
  fastify.post(
    '/customer-onboarding/service-orders/:serviceOrderId/grant',
    {
      preValidation: [
        (
          request,
          reply
        ) =>
          (fastify as any)
            .authenticate(
              request,
              reply
            ),

        (
          request,
          reply
        ) =>
          (fastify as any)
            .authorize([
              'ADMIN',
              'TECHNICIAN',
            ])(
              request,
              reply
            ),
      ],
    },
    createCustomerOnboardingGrantHandler
  );

  fastify.get(
    '/me',
    {
      preValidation: [
        (
          request,
          reply
        ) =>
          (fastify as any)
            .authenticate(
              request,
              reply
            ),
      ],
    },
    meHandler
  );
}