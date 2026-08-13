import { FastifyInstance } from 'fastify';
import {
  listEquipmentsHandler,
  getEquipmentHandler,
  upsertEquipmentHandler,
  updateEquipmentHandler,
  deleteEquipmentHandler,
} from './equipment.controller.js';

export async function equipmentRoutes(fastify: FastifyInstance) {
  const auth = (fastify as any).authenticate;
  const adminOrTech = (fastify as any).authorize(['ADMIN', 'TECHNICIAN']);

  // P0.2: Read access is open to all authenticated users.
  // CUSTOMER scope is enforced inside the controller (scoped to own customerId).
  fastify.get('/', { preValidation: [auth] }, listEquipmentsHandler);
  fastify.get('/:id', { preValidation: [auth] }, getEquipmentHandler);

  // Mutations restricted to ADMIN/TECHNICIAN only.
  fastify.put('/', { preValidation: [auth, adminOrTech] }, upsertEquipmentHandler);
  fastify.patch('/:id', { preValidation: [auth, adminOrTech] }, updateEquipmentHandler);
  fastify.delete('/:id', { preValidation: [auth, adminOrTech] }, deleteEquipmentHandler);
}
