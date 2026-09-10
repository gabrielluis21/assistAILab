import {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  getAuthUser,
  requireOrganizationId,
} from '../../core/middleware/auth.middleware.js';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  AppError,
  ForbiddenError,
} from '../../core/utils/errors.js';

import {
  customerCancelReturnSchema,
  markReturnedSchema,
  quoteDecisionSchema,
} from './service_order_customer_actions.schema.js';

import {
  authorizeFinanceCustomerMutationLive,
} from '../service_order_finance/service_order_finance.authorization.js';

import {
  executeFinanceCommand,
  parseFinanceOperationIdHeader,
} from '../service_order_finance/service_order_finance.controller.js';

import {
  customerQuoteDecisionFinanceService,
} from '../service_order_finance/customer_quote_decision.service.js';

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

  const authUser =
    getAuthUser(
      request
    );

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

  /**
   * Preserve legacy C6/C7 for pre-FIN-F02 orders.
   *
   * FIN-F02 is detected only from server-owned fields.
   */
  const orderMarker =
    await prisma
      .serviceOrder
      .findFirst({
        where: {
          id,
          customerId,
        },

        select: {
          financeCoreVersion:
            true,

          currentQuoteRevisionId:
            true,
        },
      });

  const financeCoreV2 =
    orderMarker
      ?.financeCoreVersion ===
      2 ||
    Boolean(
      orderMarker
        ?.currentQuoteRevisionId
    );

  if (
    !financeCoreV2
  ) {
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

  /**
   * FIN-F02 frozen order:
   * live auth -> exact X-Operation-Id -> H02 -> SO lock -> quote lock.
   */
  await authorizeFinanceCustomerMutationLive(
    authUser
  );

  const quoteRevisionId =
    body.quoteRevisionId;

  if (
    !quoteRevisionId
  ) {
    throw new AppError(
      'quoteRevisionId is required for FIN-F02 quote decisions',
      400
    );
  }

  const operationId =
    parseFinanceOperationIdHeader(
      request.headers[
        'x-operation-id'
      ],
      request.raw
        .rawHeaders
    );

  return executeFinanceCommand(
    reply,
    () =>
      customerQuoteDecisionFinanceService
        .decideExactQuoteRevision(
          customerId,
          userId,
          operationId,
          id,
          {
            quoteRevisionId,

            decision:
              body
                .decision,

            reason:
              body
                .reason,
          }
        )
  );
}
