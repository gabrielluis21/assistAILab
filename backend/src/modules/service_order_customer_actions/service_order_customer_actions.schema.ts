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
    /**
     * Legacy OS may omit this field.
     *
     * FIN-F02 v2 requires it at the command boundary.
     */
    quoteRevisionId:
      z.string()
        .uuid()
        .optional(),

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
