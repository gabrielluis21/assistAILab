import {
  z,
} from 'zod';

export const markReadySchema =
  z.object({
    notes:
      z.string()
        .trim()
        .min(1)
        .max(1000)
        .optional(),
  })
    .strict();

export type MarkReadyInput =
  z.infer<
    typeof markReadySchema
  >;
