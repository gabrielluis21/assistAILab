import {
    CustomerEventType,
    Prisma,
    ServiceOrderStatus,
} from '@prisma/client';

import {
    prisma,
} from '../../core/database/prisma.js';

import {
    customerEventService,
} from './customer_event.service.js';

import {
    customerProfileService,
} from './customer_profile.service.js';

type DatabaseClient =
    | typeof prisma
    | Prisma.TransactionClient;

export function mapServiceOrderStatusToCustomerEvent(
    status: ServiceOrderStatus
): CustomerEventType | null {
    switch (status) {
        case ServiceOrderStatus.ENTREGUE:
            return CustomerEventType
                .SERVICE_ORDER_COMPLETED;

        case ServiceOrderStatus.CANCELADO:
            return CustomerEventType
                .SERVICE_ORDER_CANCELLED;

        default:
            return null;
    }
}

interface ServiceOrderCreatedInput {
    serviceOrderId: string;
    customerId: string;
    organizationId: string;
    status: ServiceOrderStatus;
}

interface ServiceOrderStatusTransitionInput {
    serviceOrderId: string;
    customerId: string;
    organizationId: string;

    previousStatus:
    ServiceOrderStatus;

    newStatus:
    ServiceOrderStatus;
}

interface ServiceOrderNotApprovedInput {
    serviceOrderId: string;
    customerId: string;
    organizationId: string;

    previousStatus:
    ServiceOrderStatus;

    changedById: string;

    reason?: string;
}

export class ServiceOrderCustomerRelationshipService {
    /**
     * Nova OS.
     */
    async registerCreated(
        input:
            ServiceOrderCreatedInput,

        db:
            DatabaseClient = prisma
    ) {
        const event =
            await customerEventService
                .createServiceOrderEvent(
                    {
                        customerId:
                            input.customerId,

                        organizationId:
                            input.organizationId,

                        serviceOrderId:
                            input.serviceOrderId,

                        type:
                            CustomerEventType
                                .SERVICE_ORDER_CREATED,

                        title:
                            'Ordem de serviço criada',

                        description:
                            'Uma nova ordem de serviço foi registrada para o cliente.',

                        metadata: {
                            status:
                                input.status,
                        },
                    },

                    db
                );

        const profile =
            await customerProfileService
                .recalculate(
                    input.customerId,
                    input.organizationId,
                    db
                );

        return {
            event,
            profile,
        };
    }

    /**
     * Mudança de status comum.
     */
    async registerStatusTransition(
        input:
            ServiceOrderStatusTransitionInput,

        db:
            DatabaseClient = prisma
    ) {
        if (
            input.previousStatus ===
            input.newStatus
        ) {
            return {
                event: null,
                profile: null,
            };
        }

        const eventType =
            mapServiceOrderStatusToCustomerEvent(
                input.newStatus
            );

        /**
         * Estados operacionais intermediários
         * não geram atualmente evento CRM.
         */
        if (!eventType) {
            return {
                event: null,
                profile: null,
            };
        }

        const presentation =
            this.getEventPresentation(
                eventType
            );

        const event =
            await customerEventService
                .createServiceOrderEvent(
                    {
                        customerId:
                            input.customerId,

                        organizationId:
                            input.organizationId,

                        serviceOrderId:
                            input.serviceOrderId,

                        type:
                            eventType,

                        title:
                            presentation.title,

                        description:
                            presentation.description,

                        metadata: {
                            previousStatus:
                                input.previousStatus,

                            newStatus:
                                input.newStatus,
                        },
                    },

                    db
                );

        const profile =
            await customerProfileService
                .recalculate(
                    input.customerId,
                    input.organizationId,
                    db
                );

        return {
            event,
            profile,
        };
    }

    /**
     * Cliente recusou explicitamente
     * o orçamento.
     *
     * Este fluxo NÃO deve chamar
     * registerStatusTransition(), pois
     * não queremos gerar também
     * SERVICE_ORDER_CANCELLED.
     */
    async registerNotApproved(
        input:
            ServiceOrderNotApprovedInput,

        db:
            DatabaseClient = prisma
    ) {
        const metadata: Prisma.InputJsonObject = {
            previousStatus:
                input.previousStatus,

            newStatus:
                ServiceOrderStatus.CANCELADO,

            changedById:
                input.changedById,

            ...(input.reason
                ? {
                    reason:
                        input.reason,
                }
                : {}),
        };
        const event =
            await customerEventService
                .createServiceOrderEvent(
                    {
                        customerId:
                            input.customerId,

                        organizationId:
                            input.organizationId,

                        serviceOrderId:
                            input.serviceOrderId,

                        type:
                            CustomerEventType
                                .SERVICE_ORDER_NOT_APPROVED,

                        title:
                            'Orçamento não aprovado',

                        description:
                            input.reason ??
                            'O cliente não aprovou o orçamento apresentado.',

                        metadata,
                    },

                    db
                );

        const profile =
            await customerProfileService
                .recalculate(
                    input.customerId,
                    input.organizationId,
                    db
                );

        return {
            event,
            profile,
        };
    }

    private getEventPresentation(
        eventType:
            CustomerEventType
    ) {
        switch (eventType) {
            case CustomerEventType
                .SERVICE_ORDER_COMPLETED:
                return {
                    title:
                        'Ordem de serviço concluída',

                    description:
                        'O atendimento foi concluído e o equipamento entregue ao cliente.',
                };

            case CustomerEventType
                .SERVICE_ORDER_CANCELLED:
                return {
                    title:
                        'Ordem de serviço cancelada',

                    description:
                        'A ordem de serviço foi cancelada.',
                };

            default:
                return {
                    title:
                        'Atualização da ordem de serviço',

                    description:
                        'Foi registrada uma atualização relacionada à ordem de serviço.',
                };
        }
    }
}

export const serviceOrderCustomerRelationshipService =
    new ServiceOrderCustomerRelationshipService();