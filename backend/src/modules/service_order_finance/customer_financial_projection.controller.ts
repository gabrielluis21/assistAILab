import type {
  FastifyReply,
  FastifyRequest,
} from 'fastify';

import {
  z,
} from 'zod';

import {
  getAuthUser,
} from '../../core/middleware/auth.middleware.js';

import {
  authorizeFinanceCustomerMutationLive,
} from './service_order_finance.authorization.js';

import {
  customerFinancialProjectionService,
} from './customer_financial_projection.service.js';

const customerFinanceParamsSchema =
  z.object({
    id:
      z.string()
        .uuid(),
  })
    .strict();

export async function customerFinancialProjectionHandler(
  request:
    FastifyRequest,
  reply:
    FastifyReply
) {
  const authUser =
    getAuthUser(
      request
    );

  /**
   * Reuse the established FIN-F02 live CUSTOMER identity gate.
   * This is a read route, so there is intentionally no H02/operation id.
   */
  const customerId =
    await authorizeFinanceCustomerMutationLive(
      authUser
    );

  const params =
    customerFinanceParamsSchema
      .parse(
        request.params
      );

  const projection =
    await customerFinancialProjectionService
      .getForCustomer(
        customerId,
        params.id
      );

  return reply.send(
    projection
  );
}
