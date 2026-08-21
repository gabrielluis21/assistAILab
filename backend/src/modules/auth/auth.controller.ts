import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import {
  registerSchema,
  loginSchema,
  claimCustomerOnboardingSchema,
} from './auth.schema.js';

import {
  AuthService,
} from './auth.service.js';

import {
  CustomerOnboardingService,
} from './customer_onboarding.service.js';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

const authService =
  new AuthService();

const customerOnboardingService =
  new CustomerOnboardingService();

export async function registerHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body =
    registerSchema.parse(
      request.body
    );

  const user =
    await authService
      .register(body);

  return reply
    .status(201)
    .send({
      user,
    });
}

export async function loginHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body =
    loginSchema.parse(
      request.body
    );

  const user =
    await authService
      .validateCredentials(
        body
      );

  const token =
    (request.server as any)
      .jwt
      .sign(
        {
          sub:
            user.id,

          role:
            user.role,

          name:
            user.name,

          customerId:
            user.customerId ??
            null,

          /**
           * CUSTOMER = null.
           *
           * ADMIN / TECH = Membership.
           */
          organizationId:
            user.organizationId ??
            null,
        },

        {
          expiresIn:
            '8h',
        }
      );

  return reply.send({
    token,
    user,
  });
}

export async function meHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser =
    getAuthUser(request);

  const user =
    await authService
      .getCurrentUser(
        authUser.sub
      );

  return reply.send({
    user,
  });
}

/**
 * ============================================================
 * CREATE CUSTOMER ONBOARDING GRANT
 * ============================================================
 *
 * ADMIN / TECH.
 */
export async function createCustomerOnboardingGrantHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const {
    serviceOrderId,
  } =
    request.params as {
      serviceOrderId: string;
    };

  const authUser =
    getAuthUser(request);

  const organizationId =
    requireOrganizationId(
      authUser
    );

  const grant =
    await customerOnboardingService
      .createGrant(
        serviceOrderId,
        organizationId,
        authUser.sub
      );

  return reply
    .status(201)
    .send({
      grant,
    });
}

/**
 * ============================================================
 * CLAIM CUSTOMER ONBOARDING
 * ============================================================
 *
 * Público.
 *
 * A identidade vem do token → OS → Customer.
 */
export async function claimCustomerOnboardingHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body =
    claimCustomerOnboardingSchema
      .parse(
        request.body
      );

  const result =
    await customerOnboardingService
      .claim(
        body.token,
        body.password
      );

  return reply.send(
    result
  );
}