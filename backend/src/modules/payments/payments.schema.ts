import { z } from 'zod';

import {
  positiveMoneyMinorSchema,
} from '../../core/money/money.js';

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
    serviceOrderId:
      z.string().uuid(),

    amountMinor:
      positiveMoneyMinorSchema,

    method:
      paymentMethodSchema,

    cardInstallmentCount:
      z.number()
        .int()
        .min(1)
        .max(24)
        .optional(),

    notes:
      z.string()
        .max(1000)
        .optional(),
  })
  .strict()
  .superRefine(
    (
      value,
      ctx
    ) => {
      if (
        value
          .cardInstallmentCount !==
          undefined &&
        value.method !==
          'CARTAO_CREDITO'
      ) {
        ctx.addIssue({
          code:
            z.ZodIssueCode.custom,
          path: [
            'cardInstallmentCount',
          ],
          message:
            'cardInstallmentCount is allowed only for CARTAO_CREDITO',
        });
      }
    }
  );

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
