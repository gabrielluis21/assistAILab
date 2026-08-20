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