import {
  FastifyInstance,
} from 'fastify';

import {
  authorizeEquipmentAcquisitionHandler,
  completeEquipmentAcquisitionHandler,
  createEquipmentAcquisitionHandler,
  getEquipmentAcquisitionHandler,
  listEquipmentAcquisitionsHandler,
  rejectEquipmentAcquisitionHandler,
} from './equipment_acquisitions.controller.js';

export async function equipmentAcquisitionRoutes(
  fastify:
    FastifyInstance
) {
  const auth =
    (fastify as any)
      .authenticate;

  const adminOrTech =
    (fastify as any)
      .authorize([
        'ADMIN',
        'TECHNICIAN',
      ]);

  const customerOnly =
    (fastify as any)
      .authorize([
        'CUSTOMER',
      ]);

  /**
   * Leituras:
   *
   * - CUSTOMER → próprias propostas;
   * - ADMIN/TECH → própria Organization.
   */
  fastify.get(
    '/',
    {
      preValidation: [
        auth,
      ],
    },
    listEquipmentAcquisitionsHandler
  );

  fastify.get(
    '/:id',
    {
      preValidation: [
        auth,
      ],
    },
    getEquipmentAcquisitionHandler
  );

  /**
   * Organization apresenta proposta.
   */
  fastify.post(
    '/',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    createEquipmentAcquisitionHandler
  );

  /**
   * Customer decide.
   */
  fastify.post(
    '/:id/authorize',
    {
      preValidation: [
        auth,
        customerOnly,
      ],
    },
    authorizeEquipmentAcquisitionHandler
  );

  fastify.post(
    '/:id/reject',
    {
      preValidation: [
        auth,
        customerOnly,
      ],
    },
    rejectEquipmentAcquisitionHandler
  );

  /**
   * Organization efetiva a transferência
   * somente após autorização.
   */
  fastify.post(
    '/:id/complete',
    {
      preValidation: [
        auth,
        adminOrTech,
      ],
    },
    completeEquipmentAcquisitionHandler
  );
}
