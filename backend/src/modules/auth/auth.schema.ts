import { z } from 'zod';

export const registerSchema = z.object({
  name: z.string().min(2),
  email: z.string().email(),
  password: z.string().min(8),
  role: z.enum(['TECHNICIAN', 'CUSTOMER']).default('TECHNICIAN'),
  // Optional: link a CUSTOMER user to an existing Customer record by ID.
  // If not provided for CUSTOMER role, a new Customer record is auto-provisioned.
  customerId: z.string().uuid().optional(),
});

export const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(1),
});

export type RegisterInput = z.infer<typeof registerSchema>;
export type LoginInput = z.infer<typeof loginSchema>;
