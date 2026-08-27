import { z } from 'zod';

export const paymentMethodSchema = z.enum([
  'DINHEIRO',
  'CARTAO_CREDITO',
  'CARTAO_DEBITO',
  'PIX',
  'TRANSFERENCIA',
  'BOLETO',
]);

export const paymentListQuerySchema = z
  .object({
    serviceOrderId: z.string().uuid().optional(),
    customerId: z.string().uuid().optional(),
  })
  .strict();

export const paymentIdParamsSchema = z
  .object({
    id: z.string().uuid(),
  })
  .strict();

export const createPaymentSchema = z
  .object({
    serviceOrderId: z.string().uuid(),
    amountMinor: z
      .number()
      .int()
      .positive()
      .safe()
      .max(999_999_999_999_999),
    method: paymentMethodSchema,
    notes: z.string().max(1000).optional(),
  })
  .strict();

export const updatePaymentStatusSchema = z
  .object({
    status: z.enum([
      'CONFIRMED',
      'CANCELLED',
    ]),
  })
  .strict();

export const operationIdHeaderSchema =
  z.string().uuid();

export type PaymentListQuery =
  z.infer<typeof paymentListQuerySchema>;

export type CreatePaymentInput =
  z.infer<typeof createPaymentSchema>;

export type UpdatePaymentStatusInput =
  z.infer<typeof updatePaymentStatusSchema>;
