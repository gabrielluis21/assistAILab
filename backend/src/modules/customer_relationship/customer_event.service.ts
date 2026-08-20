import {
    CustomerEventType,
    Prisma,
} from '@prisma/client';

import { prisma } from '../../core/database/prisma.js';

type DatabaseClient =
    | typeof prisma
    | Prisma.TransactionClient;

export interface CreateCustomerEventInput {
    customerId: string;
    organizationId: string;
    type: CustomerEventType;
    serviceOrderId?: string;
    title: string;
    description?: string;
    metadata?: Prisma.InputJsonValue;
}

export class CustomerEventService {
    async create(
        input: CreateCustomerEventInput,
        db: DatabaseClient = prisma
    ) {
        return db.customerEvent.create({
            data: {
                customerId: input.customerId,
                organizationId: input.organizationId,
                type: input.type,

                serviceOrderId:
                    input.serviceOrderId ?? null,

                title: input.title,

                description:
                    input.description ?? null,

                metadata:
                    input.metadata ?? undefined,
            },
        });
    }

    async createServiceOrderEvent(
        input: {
            customerId: string;
            organizationId: string;
            serviceOrderId: string;
            type: CustomerEventType;
            title: string;
            description?: string;
            metadata?: Prisma.InputJsonValue;
        },
        db: DatabaseClient = prisma
    ) {
        return this.create(
            {
                customerId: input.customerId,
                organizationId: input.organizationId,
                serviceOrderId: input.serviceOrderId,
                type: input.type,
                title: input.title,
                description: input.description,
                metadata: input.metadata,
            },
            db
        );
    }
}

export const customerEventService =
    new CustomerEventService();