import {
    CustomerEventType,
    CustomerRiskLevel,
    PaymentStatus,
    Prisma,
    ServiceOrderStatus,
} from '@prisma/client';

import {
    prisma,
} from '../../core/database/prisma.js';

import {
    NotFoundError,
} from '../../core/utils/errors.js';

type DatabaseClient =
    | typeof prisma
    | Prisma.TransactionClient;

export class CustomerProfileService {
    /**
     * Recalcula completamente o perfil CRM
     * de um cliente dentro de uma organização.
     *
     * CustomerProfile é uma projeção analítica.
     *
     * Fontes de verdade:
     * - ServiceOrder
     * - Payment
     * - CustomerEvent
     * - CustomerFeedback
     */
    async recalculate(
        customerId: string,
        organizationId: string,
        db: DatabaseClient = prisma
    ) {
        /**
         * Descobre a relação específica:
         *
         * Customer
         *     ↓
         * CustomerOrganization
         *     ↓
         * CustomerProfile
         */
        const customerOrganization =
            await db.customerOrganization.findUnique({
                where: {
                    customerId_organizationId: {
                        customerId,
                        organizationId,
                    },
                },
            });

        if (!customerOrganization) {
            throw new NotFoundError(
                'Customer is not associated with this organization'
            );
        }

        const [
            orders,
            payments,
            notApprovedEvents,
            returnedEvents,
            feedbackAggregate,
        ] = await Promise.all([
            /**
             * Todas as OS do cliente
             * dentro da organização atual.
             */
            db.serviceOrder.findMany({
                where: {
                    customerId,
                    organizationId,
                },

                select: {
                    id: true,
                    status: true,
                    createdAt: true,
                },

                orderBy: {
                    createdAt: 'asc',
                },
            }),

            /**
             * Pagamentos realmente confirmados.
             */
            db.payment.findMany({
                where: {
                    customerId,

                    status:
                        PaymentStatus.CONFIRMED,

                    serviceOrder: {
                        organizationId,
                    },
                },

                select: {
                    amount: true,
                },
            }),

            /**
             * OS cujo orçamento foi efetivamente
             * recusado pelo cliente.
             */
            db.customerEvent.findMany({
                where: {
                    customerId,
                    organizationId,

                    type:
                        CustomerEventType
                            .SERVICE_ORDER_NOT_APPROVED,

                    serviceOrderId: {
                        not: null,
                    },
                },

                select: {
                    serviceOrderId: true,
                },
            }),

            /**
             * OS que tiveram retorno/devolução.
             */
            db.customerEvent.findMany({
                where: {
                    customerId,
                    organizationId,

                    type:
                        CustomerEventType
                            .SERVICE_ORDER_RETURNED,

                    serviceOrderId: {
                        not: null,
                    },
                },

                select: {
                    serviceOrderId: true,
                },
            }),

            /**
             * Feedback do cliente somente
             * nesta organização.
             */
            db.customerFeedback.aggregate({
                where: {
                    customerId,
                    organizationId,

                    rating: {
                        not: null,
                    },
                },

                _avg: {
                    rating: true,
                },

                _count: {
                    rating: true,
                },
            }),
        ]);

        /**
         * Evita duplicidade na contagem caso
         * existam múltiplos eventos para a mesma OS.
         */
        const notApprovedOrderIds =
            new Set(
                notApprovedEvents
                    .map(
                        (event) =>
                            event.serviceOrderId
                    )
                    .filter(
                        (id): id is string =>
                            id !== null
                    )
            );

        const returnedOrderIds =
            new Set(
                returnedEvents
                    .map(
                        (event) =>
                            event.serviceOrderId
                    )
                    .filter(
                        (id): id is string =>
                            id !== null
                    )
            );

        const totalServiceOrders =
            orders.length;

        const completedOrders =
            orders.filter(
                (order) =>
                    order.status ===
                    ServiceOrderStatus.ENTREGUE
            ).length;

        /**
         * Cancelamento comum.
         *
         * Uma OS recusada pelo cliente termina
         * como CANCELADO operacionalmente, porém
         * não deve ser contabilizada novamente
         * como cancelamento comum no CRM.
         */
        const cancelledOrders =
            orders.filter(
                (order) =>
                    order.status ===
                    ServiceOrderStatus.CANCELADO &&
                    !notApprovedOrderIds.has(
                        order.id
                    )
            ).length;

        const notApprovedOrders =
            notApprovedOrderIds.size;

        const returnedOrders =
            returnedOrderIds.size;

        /**
         * Valor realmente recebido.
         */
        const totalSpent =
            payments.reduce(
                (total, payment) =>
                    total +
                    Number(payment.amount),

                0
            );

        /**
         * Ticket médio inicial:
         *
         * valor recebido /
         * quantidade de atendimentos concluídos.
         */
        const averageTicket =
            completedOrders > 0
                ? totalSpent /
                completedOrders
                : 0;

        const firstServiceAt =
            orders.length > 0
                ? orders[0].createdAt
                : null;

        const lastServiceAt =
            orders.length > 0
                ? orders[
                    orders.length - 1
                ].createdAt
                : null;

        const averageRating =
            feedbackAggregate
                ._avg
                .rating ?? null;

        const feedbackCount =
            feedbackAggregate
                ._count
                .rating;

        const risk =
            this.calculateRisk({
                totalServiceOrders,
                completedOrders,
                cancelledOrders,
                notApprovedOrders,
                returnedOrders,
                lastServiceAt,
            });

        /**
         * CustomerProfile é único por
         * CustomerOrganization.
         */
        return db.customerProfile.upsert({
            where: {
                customerOrganizationId:
                    customerOrganization.id,
            },

            create: {
                customerOrganizationId:
                    customerOrganization.id,

                totalServiceOrders,
                completedOrders,
                cancelledOrders,
                notApprovedOrders,
                returnedOrders,

                totalSpent,
                averageTicket,

                averageRating,
                feedbackCount,

                firstServiceAt,
                lastServiceAt,

                riskLevel:
                    risk.level,

                riskScore:
                    risk.score,
            },

            update: {
                totalServiceOrders,
                completedOrders,
                cancelledOrders,
                notApprovedOrders,
                returnedOrders,

                totalSpent,
                averageTicket,

                averageRating,
                feedbackCount,

                firstServiceAt,
                lastServiceAt,

                riskLevel:
                    risk.level,

                riskScore:
                    risk.score,
            },
        });
    }

    /**
     * Score inicial de risco de evasão.
     *
     * No futuro poderá virar uma engine
     * configurável por organização.
     */
    private calculateRisk(data: {
        totalServiceOrders: number;
        completedOrders: number;
        cancelledOrders: number;
        notApprovedOrders: number;
        returnedOrders: number;
        lastServiceAt: Date | null;
    }): {
        level: CustomerRiskLevel;
        score: number;
    } {
        let score = 0;

        if (
            data.totalServiceOrders === 0
        ) {
            return {
                level:
                    CustomerRiskLevel.LOW,

                score: 0,
            };
        }

        /**
         * Cancelamentos comuns.
         */
        score += Math.min(
            data.cancelledOrders * 10,
            30
        );

        /**
         * Orçamentos recusados.
         */
        score += Math.min(
            data.notApprovedOrders * 8,
            25
        );

        /**
         * Retornos/devoluções.
         */
        score += Math.min(
            data.returnedOrders * 10,
            20
        );

        /**
         * Cliente possui atendimentos,
         * mas nenhum foi concluído.
         */
        if (
            data.totalServiceOrders > 0 &&
            data.completedOrders === 0
        ) {
            score += 20;
        }

        /**
         * Recência.
         */
        if (data.lastServiceAt) {
            const now =
                new Date();

            const millisecondsPerDay =
                1000 *
                60 *
                60 *
                24;

            const daysSinceLastService =
                Math.floor(
                    (
                        now.getTime() -
                        data.lastServiceAt
                            .getTime()
                    ) /
                    millisecondsPerDay
                );

            if (
                daysSinceLastService >=
                365
            ) {
                score += 40;
            } else if (
                daysSinceLastService >=
                180
            ) {
                score += 30;
            } else if (
                daysSinceLastService >=
                120
            ) {
                score += 20;
            } else if (
                daysSinceLastService >=
                90
            ) {
                score += 10;
            }
        }

        score =
            Math.min(
                score,
                100
            );

        let level:
            CustomerRiskLevel;

        if (score >= 75) {
            level =
                CustomerRiskLevel.CRITICAL;
        } else if (
            score >= 50
        ) {
            level =
                CustomerRiskLevel.HIGH;
        } else if (
            score >= 25
        ) {
            level =
                CustomerRiskLevel.MEDIUM;
        } else {
            level =
                CustomerRiskLevel.LOW;
        }

        return {
            level,
            score,
        };
    }
}

export const customerProfileService =
    new CustomerProfileService();