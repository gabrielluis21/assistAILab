import {
  FastifyInstance,
} from 'fastify';

import {
  customerCancelReturnHandler,
  customerQuoteDecisionHandler,
  markEquipmentReturnedHandler,
} from './service_order_customer_actions.controller.js';

import {
  customerFinancialProjectionHandler,
} from '../service_order_finance/customer_financial_projection.controller.js';

export async function serviceOrderCustomerActionRoutes(
  fastify:
    FastifyInstance
) {
  const auth =
    (fastify as any)
      .authenticate;

  const customerOnly =
    (fastify as any)
      .authorize([
        'CUSTOMER',
      ]);

  const adminOrTech =
    (fastify as any)
      .authorize([
        'ADMIN',
        'TECHNICIAN',
      ]);

  /**
   * C5:
   * Customer cancels own OS and requests
   * physical Equipment return.
   */
  /**
   * FIN-F02 Phase 2H - dedicated CUSTOMER financial projection.
   * Read-only: no X-Operation-Id and no generic finance entity exposure.
   */
  fastify.get(
    '/:id/customer-finance',
    {
      preValidation: [
        auth,
        customerOnly,
      ],
    },
    customerFinancialProjectionHandler
  );

  fastify.post(
    '/:id/customer-cancel-return',
    {
      preValidation: [
        auth,
        customerOnly,
      ],
    },
    customerCancelReturnHandler
  );

  /**
   * C5:
   * Staff confirms physical handover
   * after a return request.
   */
  fastify.post(
    '/:id/mark-returned',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    markEquipmentReturnedHandler
  );

  /**
   * C6/C7:
   * Customer explicitly approves or rejects
   * the quote presented for their own OS.
   */
  fastify.post(
    '/:id/quote-decision',
    {
      preValidation: [
        auth,
        customerOnly,
      ],
    },
    customerQuoteDecisionHandler
  );
}
