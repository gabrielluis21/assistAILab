import {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  customerCancelReturnSchema,
  markReturnedSchema,
  quoteDecisionSchema,
} from './service_order_customer_actions.schema.js';

import {
  serviceOrderCustomerActionsService,
} from './service_order_customer_actions.service.js';

function requireCustomerIdentity(
  request:
    FastifyRequest
): {
  customerId: string;
  userId: string;
} {
  const authUser =
    getAuthUser(
      request
    );

  if (
    authUser.role !==
      'CUSTOMER' ||
    !authUser.customerId
  ) {
    throw new ForbiddenError(
      'Customer identity is required'
    );
  }

  return {
    customerId:
      authUser.customerId,

    userId:
      authUser.sub,
  };
}

/**
 * ============================================================
 * C5 — CUSTOMER CANCELS + REQUESTS EQUIPMENT RETURN
 * ============================================================
 */
export async function customerCancelReturnHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const {
    customerId,
    userId,
  } =
    requireCustomerIdentity(
      request
    );

  const body =
    customerCancelReturnSchema
      .parse(
        request.body ?? {}
      );

  const result =
    await serviceOrderCustomerActionsService
      .cancelAndRequestReturn(
        id,
        customerId,
        userId,
        body
      );

  return reply.send(
    result
  );
}

/**
 * ============================================================
 * C5 — STAFF CONFIRMS PHYSICAL RETURN
 * ============================================================
 */
export async function markEquipmentReturnedHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const authUser =
    getAuthUser(
      request
    );

  const organizationId =
    requireOrganizationId(
      authUser
    );

  const body =
    markReturnedSchema
      .parse(
        request.body ?? {}
      );

  const result =
    await serviceOrderCustomerActionsService
      .markEquipmentReturned(
        id,
        organizationId,
        authUser.sub,
        body
      );

  return reply.send(
    result
  );
}

/**
 * ============================================================
 * C6/C7 — CUSTOMER APPROVES OR REJECTS QUOTE
 * ============================================================
 */
export async function customerQuoteDecisionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const {
    id,
  } =
    request.params as {
      id: string;
    };

  const {
    customerId,
    userId,
  } =
    requireCustomerIdentity(
      request
    );

  const body =
    quoteDecisionSchema
      .parse(
        request.body
      );

  const result =
    await serviceOrderCustomerActionsService
      .decideQuote(
        id,
        customerId,
        userId,
        body
      );

  return reply.send(
    result
  );
}
