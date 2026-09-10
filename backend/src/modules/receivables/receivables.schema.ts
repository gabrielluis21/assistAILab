import {
  z,
} from 'zod';

export const receivableIdParamsSchema =
  z.object({
    id:
      z.string()
        .uuid(),
  })
    .strict();

export const rescheduleReceivableSchema =
  z.object({
    dueDate:
      z.string()
        .regex(
          /^\d{4}-\d{2}-\d{2}$/
        ),

    reason:
      z.string()
        .trim()
        .min(1)
        .max(1000),
  })
    .strict();

export const cancelReceivableSchema =
  z.object({
    reason:
      z.string()
        .trim()
        .min(1)
        .max(1000),
  })
    .strict();

export type RescheduleReceivableInput =
  z.infer<
    typeof rescheduleReceivableSchema
  >;

export type CancelReceivableInput =
  z.infer<
    typeof cancelReceivableSchema
  >;
