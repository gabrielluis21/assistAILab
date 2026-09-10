import {
  z,
} from 'zod';

export const publishQuoteParamsSchema =
  z.object({
    id:
      z.string()
        .uuid(),
  })
    .strict();

export const publishQuoteSchema =
  z.object({
    changeReason:
      z.string()
        .trim()
        .min(1)
        .max(1000)
        .optional(),
  })
    .strict();

export const financeOperationIdHeaderSchema =
  z.string()
    .uuid();

export type PublishQuoteInput =
  z.infer<
    typeof publishQuoteSchema
  >;
