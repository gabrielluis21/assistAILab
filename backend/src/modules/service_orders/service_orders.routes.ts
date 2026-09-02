import {
  FastifyInstance,
} from 'fastify';

import {
  createServiceOrderHandler,
  getServiceOrderHandler,
  listServiceOrdersHandler,
  markServiceOrderNotApprovedHandler,
  updateServiceOrderStatusHandler,
} from './service_orders.controller.js';

import {
  publishInitialQuoteHandler,
} from '../service_order_finance/service_order_finance.controller.js';

import {
  publishCommercialQuoteRevisionHandler,
} from '../service_order_finance/commercial_quote_revision.controller.js';

import {
  resumePriorApprovedScopeHandler,
} from '../service_order_finance/resume_approved_scope.controller.js';

import {
  markReadyFinanceHandler,
} from '../service_order_finance/mark_ready.controller.js';

export async function serviceOrderRoutes(
  fastify: FastifyInstance
) {
  /**
   * Lista OS.
   *
   * CUSTOMER:
   * somente as próprias OS.
   *
   * ADMIN / TECHNICIAN:
   * somente a organização atual.
   */
  fastify.get(
    '/',
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
    listServiceOrdersHandler
  );

  /**
   * Consulta OS específica.
   */
  fastify.get(
    '/:id',
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
    getServiceOrderHandler
  );

  /**
   * Criação de OS.
   *
   * Somente equipe interna.
   */
  fastify.post(
    '/',
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
    createServiceOrderHandler
  );

  /**
   * Alteração normal de status.
   */
  fastify.patch(
    '/:id/status',
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
    updateServiceOrderStatusHandler
  );

  /**
   * Cliente recusou o orçamento.
   *
   * Embora a decisão seja do cliente,
   * neste primeiro momento o registro
   * operacional é realizado pela equipe.
   *
   * Futuramente o aplicativo do cliente
   * poderá ter uma rota própria segura
   * de aprovação/reprovação.
   */
  /**
   * FIN-F02 â€” publish immutable initial quote.
   *
   * Static role gate is only a first boundary.
   * The handler performs live user/membership authorization.
   */
  fastify.post(
    '/:id/quotes/publish',
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
    publishInitialQuoteHandler
  );

  /**
   * FIN-F02 â€” publish a commercial revision of an already
   * approved execution scope.
   */
  fastify.post(
    '/:id/quotes/revise',
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
    publishCommercialQuoteRevisionHandler
  );

  /**
   * FIN-F02 â€” explicitly resume only the last customer-approved
   * scope after a later commercial revision was rejected.
   */
  fastify.post(
    '/:id/quotes/resume-approved-scope',
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
    resumePriorApprovedScopeHandler
  );

  /**
   * FIN-F02 â€” atomically mark execution ready and issue
   * the first active receivable/schedule/installment.
   */
  fastify.post(
    '/:id/mark-ready',
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
    markReadyFinanceHandler
  );

  fastify.post(
    '/:id/not-approved',
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
    markServiceOrderNotApprovedHandler
  );
}