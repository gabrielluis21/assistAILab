import { z } from 'zod';

const paymentMethodEnum = z.enum([
  'DINHEIRO', 'CARTAO_CREDITO', 'CARTAO_DEBITO', 'PIX', 'TRANSFERENCIA', 'BOLETO',
]);

const paymentStatusEnum = z.enum(['PENDING', 'CONFIRMED', 'CANCELLED', 'REFUNDED']);

export const createPaymentSchema = z.object({
  id: z.string().uuid(),
  serviceOrderId: z.string().uuid(),
  customerId: z.string().uuid(),
  amount: z.number().positive(),
  method: paymentMethodEnum,
  notes: z.string().optional(),
});

export const updatePaymentStatusSchema = z.object({
  status: paymentStatusEnum,
  paidAt: z.string().datetime().optional(),
});

export type CreatePaymentInput = z.infer<typeof createPaymentSchema>;
export type UpdatePaymentStatusInput = z.infer<typeof updatePaymentStatusSchema>;
