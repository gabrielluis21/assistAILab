import {
    AccessGrantStatus,
    AccessGrantType,
    CustomerEventType,
    CustomerOrganizationStatus,
    EquipmentAcquisitionStatus,
    EquipmentConsentMethod,
    EquipmentOwnerType,
    EquipmentPurpose,
    OperationType,
    PaymentMethod,
    PaymentStatus,
    Prisma,
    PrismaClient,
    Role,
    ServiceOrderStatus,
    UserStatus,
} from '@prisma/client';

import bcrypt from 'bcrypt';

import {
    createHash,
} from 'node:crypto';

const prisma =
    new PrismaClient();

/**
 * ============================================================
 * ASSISTAILAB — MANUAL FRONTEND TEST SEED
 * ============================================================
 *
 * Objetivos:
 *
 * - manter seed rerunnable/idempotente;
 * - não apagar dados de desenvolvimento do usuário;
 * - usar fixtures determinísticas;
 * - produzir SyncChangeLog para popular o SQLite do Flutter;
 * - cobrir C1–C7 com dados navegáveis manualmente.
 *
 * IMPORTANTE:
 *
 * Este seed assume o hardening de Sync T049/T050:
 *
 * - ADMIN/TECH recebem PART no Pull;
 * - nextCursor avança mesmo quando um lote contém apenas
 *   alterações não autorizadas.
 */

const FIXTURE_IDS = {
    organizationA:
        '00000000-0000-0000-0000-000000000001',

    organizationB:
        '00000000-0000-0000-0000-000000000002',

    customerJoao:
        '20000000-0000-4000-8000-000000000001',

    customerMaria:
        '20000000-0000-4000-8000-000000000002',

    customerSofia:
        '20000000-0000-4000-8000-000000000003',

    customerOrgJoaoA:
        '21000000-0000-4000-8000-000000000001',

    customerOrgJoaoB:
        '21000000-0000-4000-8000-000000000002',

    customerOrgMariaA:
        '21000000-0000-4000-8000-000000000003',

    customerOrgSofiaA:
        '21000000-0000-4000-8000-000000000004',

    equipmentJoaoNotebook:
        '30000000-0000-4000-8000-000000000001',

    equipmentJoaoPhone:
        '30000000-0000-4000-8000-000000000002',

    equipmentJoaoOrgB:
        '30000000-0000-4000-8000-000000000003',

    equipmentMariaNotebook:
        '30000000-0000-4000-8000-000000000004',

    equipmentAcquisitionPending:
        '30000000-0000-4000-8000-000000000005',

    equipmentAcquisitionCompleted:
        '30000000-0000-4000-8000-000000000006',

    equipmentSofia:
        '30000000-0000-4000-8000-000000000007',

    soDiagnostic:
        '40000000-0000-4000-8000-000000000001',

    soAwaitingApproval:
        '40000000-0000-4000-8000-000000000002',

    soExecuting:
        '40000000-0000-4000-8000-000000000003',

    soReady:
        '40000000-0000-4000-8000-000000000004',

    soDelivered:
        '40000000-0000-4000-8000-000000000005',

    soReturned:
        '40000000-0000-4000-8000-000000000006',

    soRejected:
        '40000000-0000-4000-8000-000000000007',

    soOrgBDelivered:
        '40000000-0000-4000-8000-000000000008',

    soMariaDiagnostic:
        '40000000-0000-4000-8000-000000000009',

    soAcquisitionPending:
        '40000000-0000-4000-8000-000000000010',

    soAcquisitionCompleted:
        '40000000-0000-4000-8000-000000000011',

    soSofiaOnboarding:
        '40000000-0000-4000-8000-000000000012',

    acquisitionPending:
        '50000000-0000-4000-8000-000000000001',

    acquisitionCompleted:
        '50000000-0000-4000-8000-000000000002',

    onboardingGrantSofia:
        '60000000-0000-4000-8000-000000000001',

    eventDelivered:
        '70000000-0000-4000-8000-000000000001',

    eventCancelled:
        '70000000-0000-4000-8000-000000000002',

    eventReturnRequested:
        '70000000-0000-4000-8000-000000000003',

    eventReturned:
        '70000000-0000-4000-8000-000000000004',

    eventNotApproved:
        '70000000-0000-4000-8000-000000000005',

    eventOrgBDelivered:
        '70000000-0000-4000-8000-000000000006',

    eventPayment:
        '70000000-0000-4000-8000-000000000007',
} as const;

const PASSWORDS = {
    adminA:
        process.env.SEED_ADMIN_PASSWORD ??
        'Admin@123456',

    technicianA:
        process.env.SEED_TECHNICIAN_PASSWORD ??
        'Tecnico@123456',

    adminB:
        process.env.SEED_ADMIN_B_PASSWORD ??
        'AdminB@123456',

    customer:
        process.env.SEED_CUSTOMER_PASSWORD ??
        'Cliente@123456',

    pendingCustomer:
        'Pendente@123456',
} as const;

const SOFIA_ONBOARDING_TOKEN =
    process.env.SEED_ONBOARDING_TOKEN ??
    'assistailab-seed-onboarding-sofia-2026';

function daysAgo(
    days: number,
    hours = 0
): Date {
    return new Date(
        Date.now() -
        (
            (
                days * 24 +
                hours
            ) *
            60 *
            60 *
            1000
        )
    );
}

function hashSha256(
    value: string
): string {
    return createHash(
        'sha256'
    )
        .update(
            value
        )
        .digest(
            'hex'
        );
}

async function upsertUser(params: {
    name: string;
    email: string;
    password: string;
    role: Role;
    status?: UserStatus;
    customerId?: string | null;
}) {
    const passwordHash =
        await bcrypt.hash(
            params.password,
            12
        );

    return prisma.user.upsert({
        where: {
            email:
                params.email,
        },

        update: {
            name:
                params.name,

            passwordHash,

            role:
                params.role,

            status:
                params.status ??
                UserStatus.ACTIVE,

            customerId:
                params.customerId ??
                null,
        },

        create: {
            name:
                params.name,

            email:
                params.email,

            passwordHash,

            role:
                params.role,

            status:
                params.status ??
                UserStatus.ACTIVE,

            customerId:
                params.customerId ??
                null,
        },
    });
}

async function upsertMembership(
    userId: string,
    organizationId: string,
    role: Role
) {
    return prisma.membership.upsert({
        where: {
            userId_organizationId: {
                userId,
                organizationId,
            },
        },

        update: {
            role,
        },

        create: {
            userId,
            organizationId,
            role,
        },
    });
}

async function upsertCustomerOrganization(params: {
    id: string;
    customerId: string;
    organizationId: string;
}) {
    return prisma.customerOrganization.upsert({
        where: {
            customerId_organizationId: {
                customerId:
                    params.customerId,

                organizationId:
                    params.organizationId,
            },
        },

        update: {
            status:
                CustomerOrganizationStatus.ACTIVE,
        },

        create: {
            id:
                params.id,

            customerId:
                params.customerId,

            organizationId:
                params.organizationId,

            status:
                CustomerOrganizationStatus.ACTIVE,
        },
    });
}

async function replaceHistory(
    serviceOrderId: string,
    entries: Array<{
        previousStatus:
        ServiceOrderStatus | null;

        newStatus:
        ServiceOrderStatus;

        changedById:
        string;

        notes?:
        string;

        createdAt:
        Date;
    }>
) {
    await prisma
        .serviceOrderStatusHistory
        .deleteMany({
            where: {
                serviceOrderId,
            },
        });

    if (
        entries.length ===
        0
    ) {
        return;
    }

    await prisma
        .serviceOrderStatusHistory
        .createMany({
            data:
                entries.map(
                    (
                        entry
                    ) => ({
                        serviceOrderId,

                        previousStatus:
                            entry.previousStatus,

                        newStatus:
                            entry.newStatus,

                        changedById:
                            entry.changedById,

                        notes:
                            entry.notes,

                        createdAt:
                            entry.createdAt,
                    })
                ),
        });
}

async function upsertEvent(params: {
    id: string;
    customerId: string;
    organizationId: string;
    serviceOrderId?: string | null;
    type: CustomerEventType;
    title: string;
    description?: string | null;
    metadata?: Record<string, unknown> | null;
    createdAt: Date;
}) {
    return prisma.customerEvent.upsert({
        where: {
            id:
                params.id,
        },

        update: {
            customerId:
                params.customerId,

            organizationId:
                params.organizationId,

            serviceOrderId:
                params.serviceOrderId ??
                null,

            type:
                params.type,

            title:
                params.title,

            description:
                params.description ??
                null,

            metadata:
                params.metadata ??
                undefined,
        },

        create: {
            id:
                params.id,

            customerId:
                params.customerId,

            organizationId:
                params.organizationId,

            serviceOrderId:
                params.serviceOrderId ??
                null,

            type:
                params.type,

            title:
                params.title,

            description:
                params.description ??
                null,

            metadata:
                params.metadata ??
                undefined,

            createdAt:
                params.createdAt,
        },
    });
}

async function main() {
    console.log('');
    console.log(
        '🌱 AssistAILab — seed de testes manuais'
    );
    console.log(
        '────────────────────────────────────────'
    );

    /**
     * ==========================================================
     * ORGANIZATIONS
     * ==========================================================
     */

    const organizationA =
        await prisma
            .organization
            .upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .organizationA,
                },

                update: {
                    name:
                        'AssistAILab Tech Center',

                    document:
                        '12.345.678/0001-90',

                    email:
                        'contato@assistailab.local',

                    phone:
                        '(16) 3333-0101',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .organizationA,

                    name:
                        'AssistAILab Tech Center',

                    document:
                        '12.345.678/0001-90',

                    email:
                        'contato@assistailab.local',

                    phone:
                        '(16) 3333-0101',
                },
            });

    const organizationB =
        await prisma
            .organization
            .upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .organizationB,
                },

                update: {
                    name:
                        'AssistAILab Unidade B',

                    document:
                        '98.765.432/0001-10',

                    email:
                        'unidadeb@assistailab.local',

                    phone:
                        '(16) 3333-0202',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .organizationB,

                    name:
                        'AssistAILab Unidade B',

                    document:
                        '98.765.432/0001-10',

                    email:
                        'unidadeb@assistailab.local',

                    phone:
                        '(16) 3333-0202',
                },
            });

    /**
     * ==========================================================
     * CUSTOMERS
     * ==========================================================
     */

    const joao =
        await prisma.customer.upsert({
            where: {
                id:
                    FIXTURE_IDS
                        .customerJoao,
            },

            update: {
                name:
                    'João da Silva',

                document:
                    '111.222.333-44',

                email:
                    'joao@cliente.local',

                phone:
                    '(16) 99999-1001',

                address:
                    'Rua das Acácias, 100',
            },

            create: {
                id:
                    FIXTURE_IDS
                        .customerJoao,

                name:
                    'João da Silva',

                document:
                    '111.222.333-44',

                email:
                    'joao@cliente.local',

                phone:
                    '(16) 99999-1001',

                address:
                    'Rua das Acácias, 100',
            },
        });

    const maria =
        await prisma.customer.upsert({
            where: {
                id:
                    FIXTURE_IDS
                        .customerMaria,
            },

            update: {
                name:
                    'Maria Oliveira',

                document:
                    '222.333.444-55',

                email:
                    'maria@cliente.local',

                phone:
                    '(16) 99999-1002',

                address:
                    'Av. Central, 250',
            },

            create: {
                id:
                    FIXTURE_IDS
                        .customerMaria,

                name:
                    'Maria Oliveira',

                document:
                    '222.333.444-55',

                email:
                    'maria@cliente.local',

                phone:
                    '(16) 99999-1002',

                address:
                    'Av. Central, 250',
            },
        });

    const sofia =
        await prisma.customer.upsert({
            where: {
                id:
                    FIXTURE_IDS
                        .customerSofia,
            },

            update: {
                name:
                    'Sofia Martins',

                document:
                    '333.444.555-66',

                email:
                    'sofia@cliente.local',

                phone:
                    '(16) 99999-1003',

                address:
                    'Rua do Onboarding, 30',
            },

            create: {
                id:
                    FIXTURE_IDS
                        .customerSofia,

                name:
                    'Sofia Martins',

                document:
                    '333.444.555-66',

                email:
                    'sofia@cliente.local',

                phone:
                    '(16) 99999-1003',

                address:
                    'Rua do Onboarding, 30',
            },
        });

    /**
     * ==========================================================
     * USERS + MEMBERSHIPS
     * ==========================================================
     */

    const adminA =
        await upsertUser({
            name:
                'Administrador A',

            email:
                process.env.SEED_ADMIN_EMAIL ??
                'admin@assistailab.local',

            password:
                PASSWORDS.adminA,

            role:
                Role.ADMIN,
        });

    const technicianA =
        await upsertUser({
            name:
                'Carlos Técnico',

            email:
                'tecnico@assistailab.local',

            password:
                PASSWORDS.technicianA,

            role:
                Role.TECHNICIAN,
        });

    const adminB =
        await upsertUser({
            name:
                'Administrador B',

            email:
                'admin.b@assistailab.local',

            password:
                PASSWORDS.adminB,

            role:
                Role.ADMIN,
        });

    const joaoUser =
        await upsertUser({
            name:
                joao.name,

            email:
                'joao@cliente.local',

            password:
                PASSWORDS.customer,

            role:
                Role.CUSTOMER,

            customerId:
                joao.id,
        });

    const mariaUser =
        await upsertUser({
            name:
                maria.name,

            email:
                'maria@cliente.local',

            password:
                PASSWORDS.customer,

            role:
                Role.CUSTOMER,

            customerId:
                maria.id,
        });

    /**
     * Sofia permanece PENDING para testar onboarding.
     */
    const sofiaUser =
        await upsertUser({
            name:
                sofia.name,

            email:
                'sofia@cliente.local',

            password:
                PASSWORDS.pendingCustomer,

            role:
                Role.CUSTOMER,

            status:
                UserStatus.PENDING,

            customerId:
                sofia.id,
        });

    await upsertMembership(
        adminA.id,
        organizationA.id,
        Role.ADMIN
    );

    await upsertMembership(
        technicianA.id,
        organizationA.id,
        Role.TECHNICIAN
    );

    await upsertMembership(
        adminB.id,
        organizationB.id,
        Role.ADMIN
    );

    /**
     * CUSTOMER nunca recebe Membership.
     */

    const joaoOrgA =
        await upsertCustomerOrganization({
            id:
                FIXTURE_IDS
                    .customerOrgJoaoA,

            customerId:
                joao.id,

            organizationId:
                organizationA.id,
        });

    const joaoOrgB =
        await upsertCustomerOrganization({
            id:
                FIXTURE_IDS
                    .customerOrgJoaoB,

            customerId:
                joao.id,

            organizationId:
                organizationB.id,
        });

    const mariaOrgA =
        await upsertCustomerOrganization({
            id:
                FIXTURE_IDS
                    .customerOrgMariaA,

            customerId:
                maria.id,

            organizationId:
                organizationA.id,
        });

    const sofiaOrgA =
        await upsertCustomerOrganization({
            id:
                FIXTURE_IDS
                    .customerOrgSofiaA,

            customerId:
                sofia.id,

            organizationId:
                organizationA.id,
        });

    /**
     * ==========================================================
     * CUSTOMER PROFILES
     * ==========================================================
     */

    await prisma.customerProfile.upsert({
        where: {
            customerOrganizationId:
                joaoOrgA.id,
        },

        update: {
            totalServiceOrders:
                9,

            completedOrders:
                1,

            cancelledOrders:
                4,

            notApprovedOrders:
                1,

            returnedOrders:
                1,

            totalSpent:
                849.90,

            averageTicket:
                849.90,

            firstServiceAt:
                daysAgo(
                    90
                ),

            lastServiceAt:
                daysAgo(
                    1
                ),
        },

        create: {
            customerOrganizationId:
                joaoOrgA.id,

            totalServiceOrders:
                9,

            completedOrders:
                1,

            cancelledOrders:
                4,

            notApprovedOrders:
                1,

            returnedOrders:
                1,

            totalSpent:
                849.90,

            averageTicket:
                849.90,

            firstServiceAt:
                daysAgo(
                    90
                ),

            lastServiceAt:
                daysAgo(
                    1
                ),
        },
    });

    await prisma.customerProfile.upsert({
        where: {
            customerOrganizationId:
                joaoOrgB.id,
        },

        update: {
            totalServiceOrders:
                1,

            completedOrders:
                1,

            totalSpent:
                320,

            averageTicket:
                320,

            firstServiceAt:
                daysAgo(
                    120
                ),

            lastServiceAt:
                daysAgo(
                    120
                ),
        },

        create: {
            customerOrganizationId:
                joaoOrgB.id,

            totalServiceOrders:
                1,

            completedOrders:
                1,

            totalSpent:
                320,

            averageTicket:
                320,

            firstServiceAt:
                daysAgo(
                    120
                ),

            lastServiceAt:
                daysAgo(
                    120
                ),
        },
    });

    await prisma.customerProfile.upsert({
        where: {
            customerOrganizationId:
                mariaOrgA.id,
        },

        update: {
            totalServiceOrders:
                1,

            firstServiceAt:
                daysAgo(
                    2
                ),

            lastServiceAt:
                daysAgo(
                    2
                ),
        },

        create: {
            customerOrganizationId:
                mariaOrgA.id,

            totalServiceOrders:
                1,

            firstServiceAt:
                daysAgo(
                    2
                ),

            lastServiceAt:
                daysAgo(
                    2
                ),
        },
    });

    await prisma.customerProfile.upsert({
        where: {
            customerOrganizationId:
                sofiaOrgA.id,
        },

        update: {
            totalServiceOrders:
                1,

            firstServiceAt:
                daysAgo(
                    1
                ),

            lastServiceAt:
                daysAgo(
                    1
                ),
        },

        create: {
            customerOrganizationId:
                sofiaOrgA.id,

            totalServiceOrders:
                1,

            firstServiceAt:
                daysAgo(
                    1
                ),

            lastServiceAt:
                daysAgo(
                    1
                ),
        },
    });

    /**
     * ==========================================================
     * PARTS
     * ==========================================================
     *
     * Part continua GLOBAL no schema atual.
     */

    const partSsd =
        await prisma.part.upsert({
            where: {
                sku:
                    'SEED-SSD-NVME-1TB',
            },

            update: {
                name:
                    'SSD NVMe 1TB',

                price:
                    489.90,

                costPrice:
                    355,

                stockQuantity:
                    8,
            },

            create: {
                id:
                    '80000000-0000-4000-8000-000000000001',

                name:
                    'SSD NVMe 1TB',

                sku:
                    'SEED-SSD-NVME-1TB',

                price:
                    489.90,

                costPrice:
                    355,

                stockQuantity:
                    8,
            },
        });

    const partRam =
        await prisma.part.upsert({
            where: {
                sku:
                    'SEED-RAM-DDR4-8GB',
            },

            update: {
                name:
                    'Memória DDR4 8GB',

                price:
                    179.90,

                costPrice:
                    112,

                stockQuantity:
                    15,
            },

            create: {
                id:
                    '80000000-0000-4000-8000-000000000002',

                name:
                    'Memória DDR4 8GB',

                sku:
                    'SEED-RAM-DDR4-8GB',

                price:
                    179.90,

                costPrice:
                    112,

                stockQuantity:
                    15,
            },
        });

    const partDisplay =
        await prisma.part.upsert({
            where: {
                sku:
                    'SEED-DISPLAY-A54',
            },

            update: {
                name:
                    'Display Samsung A54',

                price:
                    620,

                costPrice:
                    435,

                stockQuantity:
                    3,
            },

            create: {
                id:
                    '80000000-0000-4000-8000-000000000003',

                name:
                    'Display Samsung A54',

                sku:
                    'SEED-DISPLAY-A54',

                price:
                    620,

                costPrice:
                    435,

                stockQuantity:
                    3,
            },
        });

    const partUsbC =
        await prisma.part.upsert({
            where: {
                sku:
                    'SEED-CONNECTOR-USBC',
            },

            update: {
                name:
                    'Conector USB-C',

                price:
                    89.90,

                costPrice:
                    34,

                stockQuantity:
                    20,
            },

            create: {
                id:
                    '80000000-0000-4000-8000-000000000004',

                name:
                    'Conector USB-C',

                sku:
                    'SEED-CONNECTOR-USBC',

                price:
                    89.90,

                costPrice:
                    34,

                stockQuantity:
                    20,
            },
        });

    const partThermal =
        await prisma.part.upsert({
            where: {
                sku:
                    'SEED-PASTA-TERMICA',
            },

            update: {
                name:
                    'Pasta térmica premium',

                price:
                    39.90,

                costPrice:
                    18,

                stockQuantity:
                    30,
            },

            create: {
                id:
                    '80000000-0000-4000-8000-000000000005',

                name:
                    'Pasta térmica premium',

                sku:
                    'SEED-PASTA-TERMICA',

                price:
                    39.90,

                costPrice:
                    18,

                stockQuantity:
                    30,
            },
        });

    /**
     * ==========================================================
     * EQUIPMENTS
     * ==========================================================
     */

    const equipments =
        await Promise.all([
            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentJoaoNotebook,
                },

                update: {
                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    organizationPurpose:
                        null,

                    type:
                        'NOTEBOOK',

                    brand:
                        'Dell',

                    model:
                        'Inspiron 15 3576',

                    serialNumber:
                        'SEED-DELL-3576-001',

                    notes:
                        'Notebook principal para cenários de OS.',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentJoaoNotebook,

                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    type:
                        'NOTEBOOK',

                    brand:
                        'Dell',

                    model:
                        'Inspiron 15 3576',

                    serialNumber:
                        'SEED-DELL-3576-001',

                    notes:
                        'Notebook principal para cenários de OS.',
                },
            }),

            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentJoaoPhone,
                },

                update: {
                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    organizationPurpose:
                        null,

                    type:
                        'CELULAR',

                    brand:
                        'Samsung',

                    model:
                        'Galaxy A54',

                    serialNumber:
                        'SEED-A54-001',

                    notes:
                        'Celular usado nos cenários de orçamento.',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentJoaoPhone,

                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    type:
                        'CELULAR',

                    brand:
                        'Samsung',

                    model:
                        'Galaxy A54',

                    serialNumber:
                        'SEED-A54-001',

                    notes:
                        'Celular usado nos cenários de orçamento.',
                },
            }),

            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentJoaoOrgB,
                },

                update: {
                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    organizationPurpose:
                        null,

                    type:
                        'TABLET',

                    brand:
                        'Apple',

                    model:
                        'iPad 9',

                    serialNumber:
                        'SEED-IPAD-001',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentJoaoOrgB,

                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    type:
                        'TABLET',

                    brand:
                        'Apple',

                    model:
                        'iPad 9',

                    serialNumber:
                        'SEED-IPAD-001',
                },
            }),

            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentMariaNotebook,
                },

                update: {
                    customerId:
                        maria.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    organizationPurpose:
                        null,

                    type:
                        'NOTEBOOK',

                    brand:
                        'Lenovo',

                    model:
                        'IdeaPad 3',

                    serialNumber:
                        'SEED-LENOVO-MARIA-001',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentMariaNotebook,

                    customerId:
                        maria.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    type:
                        'NOTEBOOK',

                    brand:
                        'Lenovo',

                    model:
                        'IdeaPad 3',

                    serialNumber:
                        'SEED-LENOVO-MARIA-001',
                },
            }),

            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentAcquisitionPending,
                },

                update: {
                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    organizationPurpose:
                        null,

                    type:
                        'NOTEBOOK',

                    brand:
                        'Acer',

                    model:
                        'Aspire antigo',

                    serialNumber:
                        'SEED-ACQ-PENDING-001',

                    notes:
                        'Equipamento com proposta de aquisição PENDING.',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentAcquisitionPending,

                    customerId:
                        joao.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    type:
                        'NOTEBOOK',

                    brand:
                        'Acer',

                    model:
                        'Aspire antigo',

                    serialNumber:
                        'SEED-ACQ-PENDING-001',

                    notes:
                        'Equipamento com proposta de aquisição PENDING.',
                },
            }),

            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentAcquisitionCompleted,
                },

                update: {
                    customerId:
                        null,

                    organizationId:
                        organizationA.id,

                    ownerType:
                        EquipmentOwnerType.ORGANIZATION,

                    organizationPurpose:
                        EquipmentPurpose.RESALE,

                    type:
                        'NOTEBOOK',

                    brand:
                        'HP',

                    model:
                        'ProBook adquirido',

                    serialNumber:
                        'SEED-ACQ-COMPLETE-001',

                    notes:
                        'Equipamento adquirido e destinado a revenda.',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentAcquisitionCompleted,

                    customerId:
                        null,

                    organizationId:
                        organizationA.id,

                    ownerType:
                        EquipmentOwnerType.ORGANIZATION,

                    organizationPurpose:
                        EquipmentPurpose.RESALE,

                    type:
                        'NOTEBOOK',

                    brand:
                        'HP',

                    model:
                        'ProBook adquirido',

                    serialNumber:
                        'SEED-ACQ-COMPLETE-001',

                    notes:
                        'Equipamento adquirido e destinado a revenda.',
                },
            }),

            prisma.equipment.upsert({
                where: {
                    id:
                        FIXTURE_IDS
                            .equipmentSofia,
                },

                update: {
                    customerId:
                        sofia.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    organizationPurpose:
                        null,

                    type:
                        'CELULAR',

                    brand:
                        'Motorola',

                    model:
                        'Moto G84',

                    serialNumber:
                        'SEED-SOFIA-001',
                },

                create: {
                    id:
                        FIXTURE_IDS
                            .equipmentSofia,

                    customerId:
                        sofia.id,

                    organizationId:
                        null,

                    ownerType:
                        EquipmentOwnerType.CUSTOMER,

                    type:
                        'CELULAR',

                    brand:
                        'Motorola',

                    model:
                        'Moto G84',

                    serialNumber:
                        'SEED-SOFIA-001',
                },
            }),
        ]);

    const [
        equipmentJoaoNotebook,
        equipmentJoaoPhone,
        equipmentJoaoOrgB,
        equipmentMariaNotebook,
        equipmentAcquisitionPending,
        equipmentAcquisitionCompleted,
        equipmentSofia,
    ] =
        equipments;

    /**
     * ==========================================================
     * SERVICE ORDERS
     * ==========================================================
     */

    async function upsertOrder(params: {
        id: string;
        organizationId: string;
        customerId: string;
        equipmentId: string;
        technicianId?: string | null;
        status: ServiceOrderStatus;
        problemDescription: string;
        diagnosis?: string | null;
        solution?: string | null;
        totalAmount?: number;
        createdAt: Date;
    }) {
        return prisma.serviceOrder.upsert({
            where: {
                id:
                    params.id,
            },

            update: {
                organizationId:
                    params.organizationId,

                customerId:
                    params.customerId,

                equipmentId:
                    params.equipmentId,

                technicianId:
                    params.technicianId ??
                    null,

                status:
                    params.status,

                problemDescription:
                    params.problemDescription,

                diagnosis:
                    params.diagnosis ??
                    null,

                solution:
                    params.solution ??
                    null,

                totalAmount:
                    params.totalAmount ??
                    0,
            },

            create: {
                id:
                    params.id,

                organizationId:
                    params.organizationId,

                customerId:
                    params.customerId,

                equipmentId:
                    params.equipmentId,

                technicianId:
                    params.technicianId ??
                    null,

                status:
                    params.status,

                problemDescription:
                    params.problemDescription,

                diagnosis:
                    params.diagnosis ??
                    null,

                solution:
                    params.solution ??
                    null,

                totalAmount:
                    params.totalAmount ??
                    0,

                createdAt:
                    params.createdAt,
            },
        });
    }

    const soDiagnostic =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soDiagnostic,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoNotebook.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.DIAGNOSTICO,

            problemDescription:
                'Notebook liga, mas apresenta lentidão severa e travamentos.',

            diagnosis:
                'Diagnóstico em andamento: verificar SSD, memória e temperatura.',

            totalAmount:
                0,

            createdAt:
                daysAgo(
                    1
                ),
        });

    const soAwaitingApproval =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soAwaitingApproval,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoPhone.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.AGUARDANDO_APROVACAO,

            problemDescription:
                'Display quebrado após queda.',

            diagnosis:
                'Necessária substituição do conjunto frontal/display.',

            solution:
                null,

            totalAmount:
                749.90,

            createdAt:
                daysAgo(
                    3
                ),
        });

    const soExecuting =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soExecuting,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoNotebook.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.EM_EXECUCAO,

            problemDescription:
                'Upgrade de desempenho e limpeza preventiva.',

            diagnosis:
                'SSD antigo degradado; recomendada substituição e limpeza.',

            solution:
                'Troca de SSD em execução.',

            totalAmount:
                689.80,

            createdAt:
                daysAgo(
                    5
                ),
        });

    const soReady =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soReady,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoPhone.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.PRONTO,

            problemDescription:
                'Conector USB-C com mau contato.',

            diagnosis:
                'Conector danificado por desgaste mecânico.',

            solution:
                'Conector USB-C substituído e testes de carga concluídos.',

            totalAmount:
                219.90,

            createdAt:
                daysAgo(
                    7
                ),
        });

    const soDelivered =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soDelivered,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoNotebook.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.ENTREGUE,

            problemDescription:
                'Sistema lento e armazenamento insuficiente.',

            diagnosis:
                'SSD com baixa saúde e memória insuficiente.',

            solution:
                'SSD NVMe 1TB + memória DDR4 8GB instalados; sistema revisado.',

            totalAmount:
                849.90,

            createdAt:
                daysAgo(
                    20
                ),
        });

    const soReturned =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soReturned,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoPhone.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.CANCELADO,

            problemDescription:
                'Cliente solicitou avaliação de dano por líquido.',

            diagnosis:
                'Oxidação extensa; cliente optou por não continuar.',

            solution:
                null,

            totalAmount:
                0,

            createdAt:
                daysAgo(
                    30
                ),
        });

    const soRejected =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soRejected,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoPhone.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.CANCELADO,

            problemDescription:
                'Troca de display original.',

            diagnosis:
                'Display deve ser substituído.',

            totalAmount:
                999,

            createdAt:
                daysAgo(
                    40
                ),
        });

    const soOrgBDelivered =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soOrgBDelivered,

            organizationId:
                organizationB.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentJoaoOrgB.id,

            technicianId:
                adminB.id,

            status:
                ServiceOrderStatus.ENTREGUE,

            problemDescription:
                'iPad não carregava corretamente.',

            diagnosis:
                'Sujeira e desgaste no conector; limpeza técnica suficiente.',

            solution:
                'Limpeza e revisão do conector.',

            totalAmount:
                320,

            createdAt:
                daysAgo(
                    120
                ),
        });

    const soMariaDiagnostic =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soMariaDiagnostic,

            organizationId:
                organizationA.id,

            customerId:
                maria.id,

            equipmentId:
                equipmentMariaNotebook.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.DIAGNOSTICO,

            problemDescription:
                'Notebook não inicia o Windows.',

            diagnosis:
                'Diagnóstico pendente.',

            totalAmount:
                0,

            createdAt:
                daysAgo(
                    2
                ),
        });

    const soAcquisitionPending =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soAcquisitionPending,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentAcquisitionPending.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.CANCELADO,

            problemDescription:
                'Equipamento antigo sem viabilidade econômica de reparo.',

            diagnosis:
                'Placa principal e bateria comprometidas.',

            solution:
                null,

            totalAmount:
                0,

            createdAt:
                daysAgo(
                    50
                ),
        });

    const soAcquisitionCompleted =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soAcquisitionCompleted,

            organizationId:
                organizationA.id,

            customerId:
                joao.id,

            equipmentId:
                equipmentAcquisitionCompleted.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.CANCELADO,

            problemDescription:
                'Equipamento sem reparo economicamente viável.',

            diagnosis:
                'Assistência apresentou proposta de compra para revenda.',

            solution:
                null,

            totalAmount:
                0,

            createdAt:
                daysAgo(
                    70
                ),
        });

    const soSofiaOnboarding =
        await upsertOrder({
            id:
                FIXTURE_IDS
                    .soSofiaOnboarding,

            organizationId:
                organizationA.id,

            customerId:
                sofia.id,

            equipmentId:
                equipmentSofia.id,

            technicianId:
                technicianA.id,

            status:
                ServiceOrderStatus.DIAGNOSTICO,

            problemDescription:
                'Celular reinicia durante o uso.',

            diagnosis:
                'Aguardando testes de bateria e placa.',

            totalAmount:
                0,

            createdAt:
                daysAgo(
                    1,
                    4
                ),
        });

    /**
     * ==========================================================
     * STATUS HISTORY
     * ==========================================================
     */

    await replaceHistory(
        soDiagnostic.id,
        []
    );

    await replaceHistory(
        soAwaitingApproval.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                changedById:
                    technicianA.id,

                notes:
                    'Diagnóstico concluído; orçamento enviado.',

                createdAt:
                    daysAgo(
                        2
                    ),
            },
        ]
    );

    await replaceHistory(
        soExecuting.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                changedById:
                    technicianA.id,

                notes:
                    'Orçamento apresentado.',

                createdAt:
                    daysAgo(
                        4,
                        12
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                newStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                changedById:
                    joaoUser.id,

                notes:
                    'Orçamento aprovado pelo cliente.',

                createdAt:
                    daysAgo(
                        4
                    ),
            },
        ]
    );

    await replaceHistory(
        soReady.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                changedById:
                    technicianA.id,

                createdAt:
                    daysAgo(
                        6,
                        12
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                newStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                changedById:
                    joaoUser.id,

                notes:
                    'Cliente aprovou o reparo.',

                createdAt:
                    daysAgo(
                        6
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                newStatus:
                    ServiceOrderStatus.PRONTO,

                changedById:
                    technicianA.id,

                createdAt:
                    daysAgo(
                        5
                    ),
            },
        ]
    );

    await replaceHistory(
        soDelivered.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                changedById:
                    technicianA.id,

                createdAt:
                    daysAgo(
                        18
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                newStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                changedById:
                    joaoUser.id,

                notes:
                    'Orçamento aprovado no app.',

                createdAt:
                    daysAgo(
                        17
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                newStatus:
                    ServiceOrderStatus.PRONTO,

                changedById:
                    technicianA.id,

                createdAt:
                    daysAgo(
                        15
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.PRONTO,

                newStatus:
                    ServiceOrderStatus.ENTREGUE,

                changedById:
                    technicianA.id,

                notes:
                    'Equipamento entregue ao cliente.',

                createdAt:
                    daysAgo(
                        14
                    ),
            },
        ]
    );

    await replaceHistory(
        soReturned.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.CANCELADO,

                changedById:
                    joaoUser.id,

                notes:
                    'Cliente cancelou e solicitou devolução.',

                createdAt:
                    daysAgo(
                        29
                    ),
            },
        ]
    );

    await replaceHistory(
        soRejected.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                changedById:
                    technicianA.id,

                createdAt:
                    daysAgo(
                        39
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                newStatus:
                    ServiceOrderStatus.CANCELADO,

                changedById:
                    joaoUser.id,

                notes:
                    'Orçamento não aprovado pelo cliente.',

                createdAt:
                    daysAgo(
                        38
                    ),
            },
        ]
    );

    await replaceHistory(
        soOrgBDelivered.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                changedById:
                    adminB.id,

                createdAt:
                    daysAgo(
                        119
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.AGUARDANDO_APROVACAO,

                newStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                changedById:
                    joaoUser.id,

                createdAt:
                    daysAgo(
                        118
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.EM_EXECUCAO,

                newStatus:
                    ServiceOrderStatus.PRONTO,

                changedById:
                    adminB.id,

                createdAt:
                    daysAgo(
                        117
                    ),
            },

            {
                previousStatus:
                    ServiceOrderStatus.PRONTO,

                newStatus:
                    ServiceOrderStatus.ENTREGUE,

                changedById:
                    adminB.id,

                createdAt:
                    daysAgo(
                        116
                    ),
            },
        ]
    );

    await replaceHistory(
        soAcquisitionPending.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.CANCELADO,

                changedById:
                    technicianA.id,

                notes:
                    'Reparo considerado economicamente inviável.',

                createdAt:
                    daysAgo(
                        49
                    ),
            },
        ]
    );

    await replaceHistory(
        soAcquisitionCompleted.id,
        [
            {
                previousStatus:
                    ServiceOrderStatus.DIAGNOSTICO,

                newStatus:
                    ServiceOrderStatus.CANCELADO,

                changedById:
                    technicianA.id,

                notes:
                    'OS encerrada após proposta de aquisição.',

                createdAt:
                    daysAgo(
                        69
                    ),
            },
        ]
    );

    /**
     * ==========================================================
     * SERVICE ORDER ITEMS
     * ==========================================================
     */

    const itemSsd =
        await prisma
            .serviceOrderItem
            .upsert({
                where: {
                    id:
                        '90000000-0000-4000-8000-000000000001',
                },

                update: {
                    serviceOrderId:
                        soDelivered.id,

                    partId:
                        partSsd.id,

                    description:
                        'SSD NVMe 1TB',

                    quantity:
                        1,

                    unitPrice:
                        489.90,

                    totalPrice:
                        489.90,
                },

                create: {
                    id:
                        '90000000-0000-4000-8000-000000000001',

                    serviceOrderId:
                        soDelivered.id,

                    partId:
                        partSsd.id,

                    description:
                        'SSD NVMe 1TB',

                    quantity:
                        1,

                    unitPrice:
                        489.90,

                    totalPrice:
                        489.90,
                },
            });

    const itemRam =
        await prisma
            .serviceOrderItem
            .upsert({
                where: {
                    id:
                        '90000000-0000-4000-8000-000000000002',
                },

                update: {
                    serviceOrderId:
                        soDelivered.id,

                    partId:
                        partRam.id,

                    description:
                        'Memória DDR4 8GB',

                    quantity:
                        1,

                    unitPrice:
                        179.90,

                    totalPrice:
                        179.90,
                },

                create: {
                    id:
                        '90000000-0000-4000-8000-000000000002',

                    serviceOrderId:
                        soDelivered.id,

                    partId:
                        partRam.id,

                    description:
                        'Memória DDR4 8GB',

                    quantity:
                        1,

                    unitPrice:
                        179.90,

                    totalPrice:
                        179.90,
                },
            });

    const itemService =
        await prisma
            .serviceOrderItem
            .upsert({
                where: {
                    id:
                        '90000000-0000-4000-8000-000000000003',
                },

                update: {
                    serviceOrderId:
                        soDelivered.id,

                    partId:
                        null,

                    description:
                        'Mão de obra, instalação e revisão',

                    quantity:
                        1,

                    unitPrice:
                        180.10,

                    totalPrice:
                        180.10,
                },

                create: {
                    id:
                        '90000000-0000-4000-8000-000000000003',

                    serviceOrderId:
                        soDelivered.id,

                    partId:
                        null,

                    description:
                        'Mão de obra, instalação e revisão',

                    quantity:
                        1,

                    unitPrice:
                        180.10,

                    totalPrice:
                        180.10,
                },
            });

    const itemDisplay =
        await prisma
            .serviceOrderItem
            .upsert({
                where: {
                    id:
                        '90000000-0000-4000-8000-000000000004',
                },

                update: {
                    serviceOrderId:
                        soAwaitingApproval.id,

                    partId:
                        partDisplay.id,

                    description:
                        'Display Samsung A54',

                    quantity:
                        1,

                    unitPrice:
                        620,

                    totalPrice:
                        620,
                },

                create: {
                    id:
                        '90000000-0000-4000-8000-000000000004',

                    serviceOrderId:
                        soAwaitingApproval.id,

                    partId:
                        partDisplay.id,

                    description:
                        'Display Samsung A54',

                    quantity:
                        1,

                    unitPrice:
                        620,

                    totalPrice:
                        620,
                },
            });

    const itemUsbC =
        await prisma
            .serviceOrderItem
            .upsert({
                where: {
                    id:
                        '90000000-0000-4000-8000-000000000005',
                },

                update: {
                    serviceOrderId:
                        soReady.id,

                    partId:
                        partUsbC.id,

                    description:
                        'Conector USB-C',

                    quantity:
                        1,

                    unitPrice:
                        89.90,

                    totalPrice:
                        89.90,
                },

                create: {
                    id:
                        '90000000-0000-4000-8000-000000000005',

                    serviceOrderId:
                        soReady.id,

                    partId:
                        partUsbC.id,

                    description:
                        'Conector USB-C',

                    quantity:
                        1,

                    unitPrice:
                        89.90,

                    totalPrice:
                        89.90,
                },
            });

    /**
     * Mantém referência à partThermal no dataset,
     * mesmo sem consumo em OS específica.
     */
    void partThermal;

    /**
     * ==========================================================
     * PAYMENTS
     * ==========================================================
     */

    const paymentDelivered =
        await prisma.payment.upsert({
            where: {
                id:
                    'a0000000-0000-4000-8000-000000000001',
            },

            update: {
                organizationId:
                    organizationA.id,

                clientOperationId:
                    'seed:payment-delivered',

                createdByUserId:
                    adminA.id,

                confirmedByUserId:
                    adminA.id,

                serviceOrderId:
                    soDelivered.id,

                customerId:
                    joao.id,

                amount:
                    849.90,

                method:
                    PaymentMethod.PIX,

                status:
                    PaymentStatus.CONFIRMED,

                notes:
                    'Pagamento integral via PIX.',

                paidAt:
                    daysAgo(
                        14
                    ),
            },

            create: {
                id:
                    'a0000000-0000-4000-8000-000000000001',

                organizationId:
                    organizationA.id,

                clientOperationId:
                    'seed:payment-delivered',

                createdByUserId:
                    adminA.id,

                confirmedByUserId:
                    adminA.id,

                serviceOrderId:
                    soDelivered.id,

                customerId:
                    joao.id,

                amount:
                    849.90,

                method:
                    PaymentMethod.PIX,

                status:
                    PaymentStatus.CONFIRMED,

                notes:
                    'Pagamento integral via PIX.',

                paidAt:
                    daysAgo(
                        14
                    ),

                createdAt:
                    daysAgo(
                        15
                    ),
            },
        });

    const paymentPending =
        await prisma.payment.upsert({
            where: {
                id:
                    'a0000000-0000-4000-8000-000000000002',
            },

            update: {
                organizationId:
                    organizationA.id,

                clientOperationId:
                    'seed:payment-pending',

                createdByUserId:
                    adminA.id,

                confirmedByUserId:
                    null,

                serviceOrderId:
                    soAwaitingApproval.id,

                customerId:
                    joao.id,

                amount:
                    749.90,

                method:
                    PaymentMethod.CARTAO_CREDITO,

                status:
                    PaymentStatus.PENDING,

                notes:
                    'Pagamento previsto após aprovação do orçamento.',

                paidAt:
                    null,
            },

            create: {
                id:
                    'a0000000-0000-4000-8000-000000000002',

                organizationId:
                    organizationA.id,

                clientOperationId:
                    'seed:payment-pending',

                createdByUserId:
                    adminA.id,

                confirmedByUserId:
                    null,

                serviceOrderId:
                    soAwaitingApproval.id,

                customerId:
                    joao.id,

                amount:
                    749.90,

                method:
                    PaymentMethod.CARTAO_CREDITO,

                status:
                    PaymentStatus.PENDING,

                notes:
                    'Pagamento previsto após aprovação do orçamento.',

                createdAt:
                    daysAgo(
                        2
                    ),
            },
        });

    const paymentOrgB =
        await prisma.payment.upsert({
            where: {
                id:
                    'a0000000-0000-4000-8000-000000000003',
            },

            update: {
                organizationId:
                    organizationB.id,

                clientOperationId:
                    'seed:payment-org-b',

                createdByUserId:
                    adminB.id,

                confirmedByUserId:
                    adminB.id,

                serviceOrderId:
                    soOrgBDelivered.id,

                customerId:
                    joao.id,

                amount:
                    320,

                method:
                    PaymentMethod.DINHEIRO,

                status:
                    PaymentStatus.CONFIRMED,

                notes:
                    'Pagamento na Unidade B.',

                paidAt:
                    daysAgo(
                        116
                    ),
            },

            create: {
                id:
                    'a0000000-0000-4000-8000-000000000003',

                organizationId:
                    organizationB.id,

                clientOperationId:
                    'seed:payment-org-b',

                createdByUserId:
                    adminB.id,

                confirmedByUserId:
                    adminB.id,

                serviceOrderId:
                    soOrgBDelivered.id,

                customerId:
                    joao.id,

                amount:
                    320,

                method:
                    PaymentMethod.DINHEIRO,

                status:
                    PaymentStatus.CONFIRMED,

                notes:
                    'Pagamento na Unidade B.',

                paidAt:
                    daysAgo(
                        116
                    ),

                createdAt:
                    daysAgo(
                        117
                    ),
            },
        });

    /**
     * ==========================================================
     * EQUIPMENT ACQUISITIONS — C4
     * ==========================================================
     */

    await prisma
        .equipmentAcquisition
        .upsert({
            where: {
                id:
                    FIXTURE_IDS
                        .acquisitionPending,
            },

            update: {
                equipmentId:
                    equipmentAcquisitionPending.id,

                customerId:
                    joao.id,

                organizationId:
                    organizationA.id,

                serviceOrderId:
                    soAcquisitionPending.id,

                purpose:
                    EquipmentPurpose.PARTS_DONOR,

                status:
                    EquipmentAcquisitionStatus.PENDING,

                offeredAmount:
                    180,

                consentMethod:
                    null,

                consentSnapshot:
                    Prisma.DbNull,

                consentHash:
                    null,

                authorizedAt:
                    null,

                rejectedAt:
                    null,

                cancelledAt:
                    null,

                completedAt:
                    null,

                notes:
                    'Proposta pendente para aproveitamento de peças.',
            },

            create: {
                id:
                    FIXTURE_IDS
                        .acquisitionPending,

                equipmentId:
                    equipmentAcquisitionPending.id,

                customerId:
                    joao.id,

                organizationId:
                    organizationA.id,

                serviceOrderId:
                    soAcquisitionPending.id,

                purpose:
                    EquipmentPurpose.PARTS_DONOR,

                status:
                    EquipmentAcquisitionStatus.PENDING,

                offeredAmount:
                    180,

                notes:
                    'Proposta pendente para aproveitamento de peças.',
            },
        });

    const completedConsentSnapshot = {
        acquisitionId:
            FIXTURE_IDS
                .acquisitionCompleted,

        equipmentId:
            equipmentAcquisitionCompleted.id,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soAcquisitionCompleted.id,

        purpose:
            EquipmentPurpose.RESALE,

        offeredAmount:
            '350.00',

        consentMethod:
            EquipmentConsentMethod.CUSTOMER_APP,

        authorizedByUserId:
            joaoUser.id,

        authorizedAt:
            daysAgo(
                68
            )
                .toISOString(),
    };

    await prisma
        .equipmentAcquisition
        .upsert({
            where: {
                id:
                    FIXTURE_IDS
                        .acquisitionCompleted,
            },

            update: {
                equipmentId:
                    equipmentAcquisitionCompleted.id,

                customerId:
                    joao.id,

                organizationId:
                    organizationA.id,

                serviceOrderId:
                    soAcquisitionCompleted.id,

                purpose:
                    EquipmentPurpose.RESALE,

                status:
                    EquipmentAcquisitionStatus.COMPLETED,

                offeredAmount:
                    350,

                consentMethod:
                    EquipmentConsentMethod.CUSTOMER_APP,

                consentSnapshot:
                    completedConsentSnapshot,

                consentHash:
                    hashSha256(
                        JSON.stringify(
                            completedConsentSnapshot
                        )
                    ),

                authorizedAt:
                    daysAgo(
                        68
                    ),

                completedAt:
                    daysAgo(
                        67
                    ),

                notes:
                    'Aquisição concluída para revenda.',
            },

            create: {
                id:
                    FIXTURE_IDS
                        .acquisitionCompleted,

                equipmentId:
                    equipmentAcquisitionCompleted.id,

                customerId:
                    joao.id,

                organizationId:
                    organizationA.id,

                serviceOrderId:
                    soAcquisitionCompleted.id,

                purpose:
                    EquipmentPurpose.RESALE,

                status:
                    EquipmentAcquisitionStatus.COMPLETED,

                offeredAmount:
                    350,

                consentMethod:
                    EquipmentConsentMethod.CUSTOMER_APP,

                consentSnapshot:
                    completedConsentSnapshot,

                consentHash:
                    hashSha256(
                        JSON.stringify(
                            completedConsentSnapshot
                        )
                    ),

                authorizedAt:
                    daysAgo(
                        68
                    ),

                completedAt:
                    daysAgo(
                        67
                    ),

                notes:
                    'Aquisição concluída para revenda.',
            },
        });

    /**
     * ==========================================================
     * CUSTOMER EVENTS
     * ==========================================================
     */

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventDelivered,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soDelivered.id,

        type:
            CustomerEventType.SERVICE_ORDER_COMPLETED,

        title:
            'Ordem de serviço concluída',

        description:
            'Equipamento reparado e entregue ao cliente.',

        metadata: {
            seed:
                true,
        },

        createdAt:
            daysAgo(
                14
            ),
    });

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventCancelled,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soReturned.id,

        type:
            CustomerEventType.SERVICE_ORDER_CANCELLED,

        title:
            'Ordem de serviço cancelada',

        description:
            'Cliente cancelou o atendimento.',

        metadata: {
            seed:
                true,
        },

        createdAt:
            daysAgo(
                29
            ),
    });

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventReturnRequested,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soReturned.id,

        type:
            CustomerEventType.OTHER,

        title:
            'Devolução solicitada',

        description:
            'Cliente solicitou a devolução do equipamento.',

        metadata: {
            kind:
                'SERVICE_ORDER_RETURN_REQUESTED',

            requestedById:
                joaoUser.id,

            seed:
                true,
        },

        createdAt:
            daysAgo(
                29
            ),
    });

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventReturned,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soReturned.id,

        type:
            CustomerEventType.SERVICE_ORDER_RETURNED,

        title:
            'Equipamento devolvido',

        description:
            'Equipamento entregue fisicamente ao cliente.',

        metadata: {
            changedById:
                technicianA.id,

            equipmentId:
                equipmentJoaoPhone.id,

            seed:
                true,
        },

        createdAt:
            daysAgo(
                28
            ),
    });

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventNotApproved,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soRejected.id,

        type:
            CustomerEventType.SERVICE_ORDER_NOT_APPROVED,

        title:
            'Orçamento não aprovado',

        description:
            'Cliente optou por não aprovar o orçamento.',

        metadata: {
            changedById:
                joaoUser.id,

            reason:
                'Valor acima do esperado',

            seed:
                true,
        },

        createdAt:
            daysAgo(
                38
            ),
    });

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventOrgBDelivered,

        customerId:
            joao.id,

        organizationId:
            organizationB.id,

        serviceOrderId:
            soOrgBDelivered.id,

        type:
            CustomerEventType.SERVICE_ORDER_COMPLETED,

        title:
            'Atendimento concluído na Unidade B',

        metadata: {
            seed:
                true,
        },

        createdAt:
            daysAgo(
                116
            ),
    });

    await upsertEvent({
        id:
            FIXTURE_IDS
                .eventPayment,

        customerId:
            joao.id,

        organizationId:
            organizationA.id,

        serviceOrderId:
            soDelivered.id,

        type:
            CustomerEventType.PAYMENT_CONFIRMED,

        title:
            'Pagamento confirmado',

        description:
            'Pagamento via PIX confirmado.',

        metadata: {
            paymentId:
                paymentDelivered.id,

            seed:
                true,
        },

        createdAt:
            daysAgo(
                14
            ),
    });

    /**
     * ==========================================================
     * SOFIA — CUSTOMER ONBOARDING FIXTURE
     * ==========================================================
     */

    const onboardingTokenHash =
        hashSha256(
            SOFIA_ONBOARDING_TOKEN
        );

    await prisma.accessGrant.upsert({
        where: {
            tokenHash:
                onboardingTokenHash,
        },

        update: {
            organizationId:
                organizationA.id,

            type:
                AccessGrantType.CUSTOMER_ONBOARDING,

            status:
                AccessGrantStatus.ACTIVE,

            targetId:
                soSofiaOnboarding.id,

            createdById:
                adminA.id,

            expiresAt:
                new Date(
                    Date.now() +
                    30 *
                    24 *
                    60 *
                    60 *
                    1000
                ),

            usedAt:
                null,

            revokedAt:
                null,
        },

        create: {
            id:
                FIXTURE_IDS
                    .onboardingGrantSofia,

            organizationId:
                organizationA.id,

            type:
                AccessGrantType.CUSTOMER_ONBOARDING,

            status:
                AccessGrantStatus.ACTIVE,

            tokenHash:
                onboardingTokenHash,

            targetId:
                soSofiaOnboarding.id,

            createdById:
                adminA.id,

            expiresAt:
                new Date(
                    Date.now() +
                    30 *
                    24 *
                    60 *
                    60 *
                    1000
                ),
        },
    });

    /**
     * ==========================================================
     * SYNC CHANGE LOG
     * ==========================================================
     *
     * REST seed direto no Prisma não passa pelo Sync Push.
     *
     * Portanto registramos snapshots CREATE para que um Flutter
     * com SQLite vazio consiga hidratar via /sync/changes.
     *
     * Ao rodar novamente:
     *
     * - dados são atualizados por upsert;
     * - apenas os change logs deste seed são recriados;
     * - dados de desenvolvimento externos ao seed são preservados.
     */

    await prisma.syncChangeLog.deleteMany({
        where: {
            cursor: {
                startsWith:
                    'seed:',
            },
        },
    });

    let syncIndex =
        0;

    async function syncCreate(
        entityType: string,
        entityId: string,
        data: Record<string, unknown>
    ) {
        syncIndex +=
            1;

        await prisma.syncChangeLog.create({
            data: {
                cursor:
                    `seed:${Date.now()}:${String(syncIndex).padStart(3, '0')}`,

                entityType,

                entityId,

                operationType:
                    OperationType.CREATE,

                data,
            },
        });
    }

    await syncCreate(
        'CUSTOMER',
        joao.id,
        {
            id:
                joao.id,

            name:
                joao.name,

            document:
                joao.document,

            email:
                joao.email,

            phone:
                joao.phone,

            address:
                joao.address,
        }
    );

    await syncCreate(
        'CUSTOMER',
        maria.id,
        {
            id:
                maria.id,

            name:
                maria.name,

            document:
                maria.document,

            email:
                maria.email,

            phone:
                maria.phone,

            address:
                maria.address,
        }
    );

    await syncCreate(
        'CUSTOMER',
        sofia.id,
        {
            id:
                sofia.id,

            name:
                sofia.name,

            document:
                sofia.document,

            email:
                sofia.email,

            phone:
                sofia.phone,

            address:
                sofia.address,
        }
    );

    for (
        const equipment of
        equipments
    ) {
        await syncCreate(
            'EQUIPMENT',
            equipment.id,
            {
                id:
                    equipment.id,

                customerId:
                    equipment.customerId,

                organizationId:
                    equipment.organizationId,

                ownerType:
                    equipment.ownerType,

                organizationPurpose:
                    equipment.organizationPurpose,

                type:
                    equipment.type,

                brand:
                    equipment.brand,

                model:
                    equipment.model,

                serialNumber:
                    equipment.serialNumber,

                notes:
                    equipment.notes,
            }
        );
    }

    const orders = [
        soDiagnostic,
        soAwaitingApproval,
        soExecuting,
        soReady,
        soDelivered,
        soReturned,
        soRejected,
        soOrgBDelivered,
        soMariaDiagnostic,
        soAcquisitionPending,
        soAcquisitionCompleted,
        soSofiaOnboarding,
    ];

    for (
        const order of
        orders
    ) {
        await syncCreate(
            'SERVICE_ORDER',
            order.id,
            {
                id:
                    order.id,

                friendlyId:
                    order.friendlyId,

                organizationId:
                    order.organizationId,

                customerId:
                    order.customerId,

                equipmentId:
                    order.equipmentId,

                technicianId:
                    order.technicianId,

                status:
                    order.status,

                problemDescription:
                    order.problemDescription,

                diagnosis:
                    order.diagnosis,

                solution:
                    order.solution,

                totalAmount:
                    Number(
                        order.totalAmount
                    ),
            }
        );
    }

    const parts = [
        partSsd,
        partRam,
        partDisplay,
        partUsbC,
        partThermal,
    ];

    for (
        const part of
        parts
    ) {
        await syncCreate(
            'PART',
            part.id,
            {
                id:
                    part.id,

                name:
                    part.name,

                sku:
                    part.sku,

                price:
                    Number(
                        part.price
                    ),

                costPrice:
                    Number(
                        part.costPrice
                    ),

                stockQuantity:
                    part.stockQuantity,
            }
        );
    }

    const orderItems = [
        itemSsd,
        itemRam,
        itemService,
        itemDisplay,
        itemUsbC,
    ];

    for (
        const item of
        orderItems
    ) {
        await syncCreate(
            'SERVICE_ORDER_ITEM',
            item.id,
            {
                id:
                    item.id,

                serviceOrderId:
                    item.serviceOrderId,

                partId:
                    item.partId,

                description:
                    item.description,

                quantity:
                    item.quantity,

                unitPrice:
                    Number(
                        item.unitPrice
                    ),

                totalPrice:
                    Number(
                        item.totalPrice
                    ),
            }
        );
    }

    const payments = [
        paymentDelivered,
        paymentPending,
        paymentOrgB,
    ];

    for (
        const payment of
        payments
    ) {
        await syncCreate(
            'PAYMENT',
            payment.id,
            {
                id:
                    payment.id,

                serviceOrderId:
                    payment.serviceOrderId,

                customerId:
                    payment.customerId,

                amount:
                    Number(
                        payment.amount
                    ),

                method:
                    payment.method,

                status:
                    payment.status,

                notes:
                    payment.notes,

                paidAt:
                    payment.paidAt
                        ?.toISOString() ??
                    null,

                createdAt:
                    payment.createdAt
                        .toISOString(),
            }
        );
    }

    /**
     * ==========================================================
     * SUMMARY
     * ==========================================================
     */

    console.log('');
    console.log(
        '✅ Seed concluído.'
    );
    console.log('');
    console.log(
        '🏢 Organization A: AssistAILab Tech Center'
    );
    console.log(
        `   ${organizationA.id}`
    );
    console.log('');
    console.log(
        '🔐 Contas para teste manual'
    );
    console.log(
        '────────────────────────────────────────'
    );

    console.log(
        `ADMIN A       ${adminA.email} / ${PASSWORDS.adminA}`
    );

    console.log(
        `TECHNICIAN A  ${technicianA.email} / ${PASSWORDS.technicianA}`
    );

    console.log(
        `ADMIN B       ${adminB.email} / ${PASSWORDS.adminB}`
    );

    console.log(
        `CUSTOMER João ${joaoUser.email} / ${PASSWORDS.customer}`
    );

    console.log(
        `CUSTOMER Maria ${mariaUser.email} / ${PASSWORDS.customer}`
    );

    console.log('');
    console.log(
        '🧪 Onboarding'
    );
    console.log(
        '────────────────────────────────────────'
    );

    console.log(
        `Customer PENDING: ${sofiaUser.email}`
    );

    console.log(
        `Token: ${SOFIA_ONBOARDING_TOKEN}`
    );

    console.log(
        `ServiceOrder: ${soSofiaOnboarding.id}`
    );

    console.log('');
    console.log(
        '📦 Dataset'
    );
    console.log(
        '────────────────────────────────────────'
    );

    console.log(
        `Customers: 3`
    );

    console.log(
        `Equipments: ${equipments.length}`
    );

    console.log(
        `Service Orders: ${orders.length}`
    );

    console.log(
        `Parts: ${parts.length}`
    );

    console.log(
        `Service Order Items: ${orderItems.length}`
    );

    console.log(
        `Payments: ${payments.length}`
    );

    console.log(
        `Sync snapshots: ${syncIndex}`
    );

    console.log('');
    console.log(
        '➡️ Próximo passo: limpar o SQLite local do app e executar o Sync Pull inicial.'
    );
    console.log('');
}

main()
    .catch(
        (
            error
        ) => {
            console.error(
                ''
            );

            console.error(
                '❌ Erro durante o seed:'
            );

            console.error(
                error
            );

            process.exit(
                1
            );
        }
    )
    .finally(
        async () => {
            await prisma.$disconnect();
        }
    );
