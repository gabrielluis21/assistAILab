import {
  z,
} from 'zod';

export const customerCancelReturnSchema =
  z.object({
    reason:
      z.string()
        .trim()
        .min(1)
        .max(1000)
        .optional(),
  });

export const quoteDecisionSchema =
  z.object({
    decision:
      z.enum([
        'APPROVE',
        'REJECT',
      ]),

    reason:
      z.string()
        .trim()
        .min(1)
        .max(1000)
        .optional(),
  });

export const markReturnedSchema =
  z.object({
    notes:
      z.string()
        .trim()
        .min(1)
        .max(1000)
        .optional(),
  });

export type CustomerCancelReturnInput =
  z.infer<
    typeof customerCancelReturnSchema
  >;

export type QuoteDecisionInput =
  z.infer<
    typeof quoteDecisionSchema
  >;

export type MarkReturnedInput =
  z.infer<
    typeof markReturnedSchema
  >;
