import { FastifyRequest, FastifyReply } from 'fastify';
import { createEquipmentSchema, updateEquipmentSchema } from './equipment.schema.js';
import { EquipmentService } from './equipment.service.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';
import { ForbiddenError } from '../../core/utils/errors.js';

const svc = new EquipmentService();

// P0.2: CUSTOMER sees only their own equipment; ADMIN/TECH see all.
export async function listEquipmentsHandler(req: FastifyRequest, reply: FastifyReply) {
  const authUser = getAuthUser(req);

  if (authUser.role === 'CUSTOMER') {
    if (!authUser.customerId) {
      throw new ForbiddenError('Access denied: no customer identity associated with this account');
    }
    const data = await svc.listByCustomer(authUser.customerId);
    return reply.send(data);
  }

  const { customerId } = req.query as { customerId?: string };
  const data = customerId ? await svc.listByCustomer(customerId) : await svc.listAll();
  return reply.send(data);
}

// P0.2: CUSTOMER can only access their own equipment.
export async function getEquipmentHandler(req: FastifyRequest, reply: FastifyReply) {
  const { id } = req.params as { id: string };
  const authUser = getAuthUser(req);

  const equipment = await svc.findById(id);

  if (authUser.role === 'CUSTOMER') {
    if (!authUser.customerId || equipment.customerId !== authUser.customerId) {
      throw new ForbiddenError('Access denied: you can only access your own equipment');
    }
  }

  return reply.send(equipment);
}

// ADMIN / TECHNICIAN only
export async function upsertEquipmentHandler(req: FastifyRequest, reply: FastifyReply) {
  const body = createEquipmentSchema.parse(req.body);
  return reply.status(200).send(await svc.upsert(body));
}

// ADMIN / TECHNICIAN only
export async function updateEquipmentHandler(req: FastifyRequest, reply: FastifyReply) {
  const { id } = req.params as { id: string };
  const body = updateEquipmentSchema.parse(req.body);
  return reply.send(await svc.update(id, body));
}

// ADMIN / TECHNICIAN only
export async function deleteEquipmentHandler(req: FastifyRequest, reply: FastifyReply) {
  const { id } = req.params as { id: string };
  await svc.delete(id);
  return reply.status(204).send();
}
