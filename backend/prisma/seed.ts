import { PrismaClient, Role, UserStatus } from '@prisma/client';
import bcrypt from 'bcrypt';

const prisma = new PrismaClient();

async function main() {
    const organizationName =
        process.env.SEED_ORGANIZATION_NAME ?? 'AssistAILab';

    const adminName =
        process.env.SEED_ADMIN_NAME ?? 'Administrador';

    const adminEmail =
        process.env.SEED_ADMIN_EMAIL ?? 'admin@assistailab.local';

    const adminPassword =
        process.env.SEED_ADMIN_PASSWORD ?? 'Admin@123456';

    console.log('🌱 Iniciando seed...');

    const organization = await prisma.organization.upsert({
        where: {
            id: '00000000-0000-0000-0000-000000000001',
        },
        update: {
            name: organizationName,
        },
        create: {
            id: '00000000-0000-0000-0000-000000000001',
            name: organizationName,
        },
    });

    const passwordHash = await bcrypt.hash(adminPassword, 12);

    const admin = await prisma.user.upsert({
        where: {
            email: adminEmail,
        },
        update: {
            name: adminName,
            passwordHash,
            role: Role.ADMIN,
            status: UserStatus.ACTIVE,
        },
        create: {
            name: adminName,
            email: adminEmail,
            passwordHash,
            role: Role.ADMIN,
            status: UserStatus.ACTIVE,
        },
    });

    await prisma.membership.upsert({
        where: {
            userId_organizationId: {
                userId: admin.id,
                organizationId: organization.id,
            },
        },
        update: {
            role: Role.ADMIN,
        },
        create: {
            userId: admin.id,
            organizationId: organization.id,
            role: Role.ADMIN,
        },
    });

    console.log('');
    console.log('✅ Seed concluído!');
    console.log('');
    console.log(`🏢 Organização: ${organization.name}`);
    console.log(`🆔 Organization ID: ${organization.id}`);
    console.log(`👤 Administrador: ${admin.name}`);
    console.log(`📧 E-mail: ${admin.email}`);
    console.log(`🔐 Status: ${admin.status}`);
    console.log(`👑 Role: ${admin.role}`);
    console.log('');
}

main()
    .catch((error) => {
        console.error('❌ Erro durante o seed:');
        console.error(error);
        process.exit(1);
    })
    .finally(async () => {
        await prisma.$disconnect();
    });