import { z } from 'zod';

export const outboxEntrySchema = z.object({
  operationId: z.string().uuid(),
  deviceId: z.string().optional(),
  userId: z.string().optional(),
  entityType: z.string(),
  entityId: z.string(),
  operationType: z.enum(['CREATE', 'UPDATE', 'DELETE']),
  payload: z.record(z.any()),
  createdAt: z.string(),
});

export const pushSyncSchema = z.object({
  entries: z.array(outboxEntrySchema),
});

export const pullSyncQuerySchema = z.object({
  cursor: z.string().optional(),
  limit: z.coerce.number().min(1).max(100).default(50),
});

export type OutboxEntry = z.infer<typeof outboxEntrySchema>;
export type PushSyncInput = z.infer<typeof pushSyncSchema>;
export type PullSyncQuery = z.infer<typeof pullSyncQuerySchema>;
