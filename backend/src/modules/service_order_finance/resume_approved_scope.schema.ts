import { z } from 'zod';

export const resumeApprovedScopeSchema =
  z.object({
    reason:
      z.string()
        .trim()
        .min(1)
        .max(1000),
  })
    .strict();

export type ResumeApprovedScopeInput =
  z.infer<typeof resumeApprovedScopeSchema>;
