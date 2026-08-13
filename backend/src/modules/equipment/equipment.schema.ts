import { z } from 'zod';

export const createEquipmentSchema = z.object({
  id: z.string().uuid(),
  customerId: z.string().uuid(),
  type: z.string().min(1),
  brand: z.string().min(1),
  model: z.string().min(1),
  serialNumber: z.string().optional(),
  notes: z.string().optional(),
});

export const updateEquipmentSchema = z.object({
  type: z.string().min(1).optional(),
  brand: z.string().min(1).optional(),
  model: z.string().min(1).optional(),
  serialNumber: z.string().optional(),
  notes: z.string().optional(),
});

export type CreateEquipmentInput = z.infer<typeof createEquipmentSchema>;
export type UpdateEquipmentInput = z.infer<typeof updateEquipmentSchema>;
