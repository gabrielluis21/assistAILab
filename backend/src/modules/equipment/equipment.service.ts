import { prisma } from '../../core/database/prisma.js';
import { CreateEquipmentInput, UpdateEquipmentInput } from './equipment.schema.js';
import { NotFoundError } from '../../core/utils/errors.js';

export class EquipmentService {
  async listAll() {
    return prisma.equipment.findMany({
      orderBy: { updatedAt: 'desc' },
      include: { customer: { select: { id: true, name: true } } },
    });
  }

  async listByCustomer(customerId: string) {
    return prisma.equipment.findMany({
      where: { customerId },
      orderBy: { updatedAt: 'desc' },
    });
  }

  async findById(id: string) {
    const equipment = await prisma.equipment.findUnique({
      where: { id },
      include: {
        customer: { select: { id: true, name: true } },
        serviceOrders: { select: { id: true, status: true, updatedAt: true }, take: 10 },
      },
    });
    if (!equipment) throw new NotFoundError(`Equipment ${id} not found`);
    return equipment;
  }

  async upsert(data: CreateEquipmentInput) {
    return prisma.equipment.upsert({
      where: { id: data.id },
      create: {
        id: data.id,
        customerId: data.customerId,
        type: data.type,
        brand: data.brand,
        model: data.model,
        serialNumber: data.serialNumber,
        notes: data.notes,
      },
      update: {
        type: data.type,
        brand: data.brand,
        model: data.model,
        serialNumber: data.serialNumber,
        notes: data.notes,
        updatedAt: new Date(),
      },
    });
  }

  async update(id: string, data: UpdateEquipmentInput) {
    const existing = await prisma.equipment.findUnique({ where: { id } });
    if (!existing) throw new NotFoundError(`Equipment ${id} not found`);

    return prisma.equipment.update({
      where: { id },
      data: { ...data, updatedAt: new Date() },
    });
  }

  async delete(id: string) {
    const existing = await prisma.equipment.findUnique({ where: { id } });
    if (!existing) throw new NotFoundError(`Equipment ${id} not found`);
    return prisma.equipment.delete({ where: { id } });
  }
}
