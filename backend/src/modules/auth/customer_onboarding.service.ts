import bcrypt from 'bcrypt';

import {
    createHash,
    randomBytes,
} from 'node:crypto';

import {
    AccessGrantStatus,
    AccessGrantType,
    Role,
    UserStatus,
} from '@prisma/client';

import {
    prisma,
} from '../../core/database/prisma.js';

import {
    ConflictError,
    ForbiddenError,
    NotFoundError,
    UnauthorizedError,
} from '../../core/utils/errors.js';

const SALT_ROUNDS =
    12;

/**
 * QR/token de onboarding é:
 *
 * - temporário;
 * - uso único;
 * - armazenado somente como hash.
 *
 * 30 minutos inicialmente.
 */
const CUSTOMER_ONBOARDING_TTL_MS =
    30 * 60 * 1000;

function hashToken(
    token: string
): string {
    return createHash(
        'sha256'
    )
        .update(token)
        .digest('hex');
}

export class CustomerOnboardingService {
    /**
     * ========================================================
     * GERA CUSTOMER_ONBOARDING
     * ========================================================
     *
     * Chamado pela equipe da assistência.
     *
     * targetId = ServiceOrder.id
     */
    async createGrant(
        serviceOrderId: string,
        organizationId: string,
        createdById: string
    ) {
        const order =
            await prisma
                .serviceOrder
                .findFirst({
                    where: {
                        id:
                            serviceOrderId,

                        organizationId,
                    },

                    select: {
                        id:
                            true,

                        customerId:
                            true,
                    },
                });

        if (!order) {
            throw new NotFoundError(
                'Service Order not found'
            );
        }

        /**
         * A relação precisa continuar válida.
         */
        const relationship =
            await prisma
                .customerOrganization
                .findUnique({
                    where: {
                        customerId_organizationId: {
                            customerId:
                                order.customerId,

                            organizationId,
                        },
                    },
                });

        if (
            !relationship ||
            relationship.status !==
            'ACTIVE'
        ) {
            throw new ForbiddenError(
                'Customer relationship with the current organization is not active'
            );
        }

        /**
         * Token bruto nunca vai para o banco.
         */
        const token =
            randomBytes(32)
                .toString(
                    'base64url'
                );

        const tokenHash =
            hashToken(token);

        const expiresAt =
            new Date(
                Date.now() +
                CUSTOMER_ONBOARDING_TTL_MS
            );

        await prisma
            .accessGrant
            .create({
                data: {
                    organizationId,

                    type:
                        AccessGrantType
                            .CUSTOMER_ONBOARDING,

                    status:
                        AccessGrantStatus
                            .ACTIVE,

                    tokenHash,

                    targetId:
                        order.id,

                    createdById,

                    expiresAt,
                },
            });

        /**
         * Sem nome, email, customerId etc.
         *
         * O token é a única informação sensível
         * necessária para o QR.
         */
        return {
            token,
            expiresAt,
            serviceOrderId:
                order.id,
        };
    }

    /**
     * ========================================================
     * CLAIM
     * ========================================================
     *
     * token
     *   ↓
     * AccessGrant
     *   ↓
     * ServiceOrder
     *   ↓
     * Customer
     *   ↓
     * User CUSTOMER
     */
    async claim(
        token: string,
        password: string
    ) {
        const tokenHash =
            hashToken(token);

        const grant =
            await prisma
                .accessGrant
                .findUnique({
                    where: {
                        tokenHash,
                    },
                });

        if (
            !grant ||
            grant.type !==
            AccessGrantType
                .CUSTOMER_ONBOARDING
        ) {
            throw new UnauthorizedError(
                'Invalid onboarding token'
            );
        }

        if (
            grant.status !==
            AccessGrantStatus.ACTIVE
        ) {
            throw new ConflictError(
                'Onboarding token is no longer active'
            );
        }

        const now =
            new Date();

        if (
            grant.expiresAt <=
            now
        ) {
            await prisma
                .accessGrant
                .updateMany({
                    where: {
                        id:
                            grant.id,

                        status:
                            AccessGrantStatus
                                .ACTIVE,
                    },

                    data: {
                        status:
                            AccessGrantStatus
                                .EXPIRED,
                    },
                });

            throw new ConflictError(
                'Onboarding token has expired'
            );
        }

        if (!grant.targetId) {
            throw new ConflictError(
                'Onboarding token has no Service Order target'
            );
        }

        const passwordHash =
            await bcrypt.hash(
                password,
                SALT_ROUNDS
            );

        /**
         * Tudo acontece atomicamente:
         *
         * token USED + User ACTIVE
         *
         * Se qualquer etapa falhar,
         * o grant volta a ACTIVE pelo rollback.
         */
        return prisma
            .$transaction(
                async (tx) => {
                    /**
                     * Reserva o token atomicamente.
                     *
                     * Impede dois claims simultâneos.
                     */
                    const reservation =
                        await tx
                            .accessGrant
                            .updateMany({
                                where: {
                                    id:
                                        grant.id,

                                    status:
                                        AccessGrantStatus
                                            .ACTIVE,

                                    expiresAt: {
                                        gt:
                                            now,
                                    },
                                },

                                data: {
                                    status:
                                        AccessGrantStatus
                                            .USED,

                                    usedAt:
                                        now,
                                },
                            });

                    if (
                        reservation.count !==
                        1
                    ) {
                        throw new ConflictError(
                            'Onboarding token is no longer active'
                        );
                    }

                    /**
                     * A OS precisa continuar pertencendo
                     * à Organization que emitiu o grant.
                     */
                    const order =
                        await tx
                            .serviceOrder
                            .findFirst({
                                where: {
                                    id:
                                        grant.targetId!,

                                    organizationId:
                                        grant.organizationId,
                                },

                                select: {
                                    id:
                                        true,

                                    customerId:
                                        true,
                                },
                            });

                    if (!order) {
                        throw new ConflictError(
                            'Onboarding Service Order is no longer available'
                        );
                    }

                    const relationship =
                        await tx
                            .customerOrganization
                            .findUnique({
                                where: {
                                    customerId_organizationId: {
                                        customerId:
                                            order.customerId,

                                        organizationId:
                                            grant.organizationId,
                                    },
                                },
                            });

                    if (
                        !relationship ||
                        relationship.status !==
                        'ACTIVE'
                    ) {
                        throw new ForbiddenError(
                            'Customer relationship with the organization is not active'
                        );
                    }

                    /**
                     * Customer verdadeiro vem da OS,
                     * nunca do payload.
                     */
                    const customer =
                        await tx
                            .customer
                            .findUnique({
                                where: {
                                    id:
                                        order.customerId,
                                },

                                include: {
                                    user:
                                        true,
                                },
                            });

                    if (!customer) {
                        throw new ConflictError(
                            'Customer associated with the Service Order no longer exists'
                        );
                    }

                    /**
                     * Cadastro prévio pode existir sem email,
                     * porque Customer.email é opcional.
                     *
                     * Não vamos alterar identidade
                     * silenciosamente pelo claim.
                     */
                    const loginEmail =
                        customer.user?.email ??
                        customer.email;

                    if (!loginEmail) {
                        throw new ConflictError(
                            'Customer onboarding requires a registered email address'
                        );
                    }

                    let user;

                    /**
                     * Public register pode ter criado:
                     *
                     * Customer + User PENDING.
                     *
                     * Nesse caso reutilizamos o User.
                     */
                    if (customer.user) {
                        if (
                            customer.user.status ===
                            UserStatus.ACTIVE
                        ) {
                            throw new ConflictError(
                                'Customer account is already active'
                            );
                        }

                        if (
                            customer.user.status !==
                            UserStatus.PENDING
                        ) {
                            throw new ForbiddenError(
                                'Customer account cannot be activated through onboarding'
                            );
                        }

                        user =
                            await tx
                                .user
                                .update({
                                    where: {
                                        id:
                                            customer.user.id,
                                    },

                                    data: {
                                        passwordHash,

                                        role:
                                            Role.CUSTOMER,

                                        status:
                                            UserStatus.ACTIVE,
                                    },
                                });
                    } else {
                        /**
                         * Garante que o email não esteja
                         * vinculado a outro User/Customer.
                         */
                        const emailOwner =
                            await tx
                                .user
                                .findUnique({
                                    where: {
                                        email:
                                            loginEmail,
                                    },
                                });

                        if (emailOwner) {
                            throw new ConflictError(
                                'A user with this email already exists'
                            );
                        }

                        user =
                            await tx
                                .user
                                .create({
                                    data: {
                                        name:
                                            customer.name,

                                        email:
                                            loginEmail,

                                        phone:
                                            customer.phone,

                                        passwordHash,

                                        role:
                                            Role.CUSTOMER,

                                        status:
                                            UserStatus.ACTIVE,

                                        customerId:
                                            customer.id,
                                    },
                                });
                    }

                    return {
                        user: {
                            id:
                                user.id,

                            name:
                                user.name,

                            email:
                                user.email,

                            phone:
                                user.phone,

                            role:
                                user.role,

                            status:
                                user.status,

                            customerId:
                                user.customerId,
                        },
                    };
                }
            );
    }
}