import { z } from 'zod';
import { CustomerEventType } from '@prisma/client';

export const createCustomerEventSchema = z.object({
    customerId: z.string().uuid(),
    organizationId: z.string().uuid().optional(),

    type: z.nativeEnum(CustomerEventType),

    serviceOrderId: z.string().uuid().optional(),

    title: z.string().min(1).max(191),

    description: z.string().optional(),

    metadata: z.record(z.any()).optional(),
});

export type CreateCustomerEventInput = z.infer<
    typeof createCustomerEventSchema
>;