import bcrypt from 'bcrypt';
import { prisma } from '../../core/database/prisma.js';

import {
  RegisterInput,
  LoginInput,
} from './auth.schema.js';

import {
  UnauthorizedError,
  ForbiddenError,
  ConflictError,
} from '../../core/utils/errors.js';

const SALT_ROUNDS = 12;

export class AuthService {
  async register(input: RegisterInput) {
    const existingUser = await prisma.user.findUnique({
      where: {
        email: input.email,
      },
    });

    if (existingUser) {
      throw new ConflictError(
        'A user with this email already exists'
      );
    }

    const passwordHash = await bcrypt.hash(
      input.password,
      SALT_ROUNDS
    );

    return prisma.$transaction(async (tx) => {
      const customer = await tx.customer.create({
        data: {
          name: input.name,
          email: input.email,
          phone: input.phone,
        },
      });

      const user = await tx.user.create({
        data: {
          name: input.name,
          email: input.email,
          phone: input.phone,
          passwordHash,
          role: 'CUSTOMER',
          status: 'PENDING',
          customerId: customer.id,
        },
      });

      return {
        id: user.id,
        name: user.name,
        email: user.email,
        phone: user.phone,
        role: user.role,
        status: user.status,
        customerId: user.customerId,
      };
    });
  }

  async validateCredentials(input: LoginInput) {
    const user = await prisma.user.findUnique({
      where: {
        email: input.email,
      },
      include: {
        memberships: {
          include: {
            organization: true,
          },
          orderBy: {
            createdAt: 'asc',
          },
        },
      },
    });

    if (!user) {
      throw new UnauthorizedError('Invalid credentials');
    }

    if (user.status !== 'ACTIVE') {
      throw new ForbiddenError(
        'User account is not active'
      );
    }

    const valid = await bcrypt.compare(
      input.password,
      user.passwordHash
    );

    if (!valid) {
      throw new UnauthorizedError('Invalid credentials');
    }

    if (user.memberships.length === 0) {
      throw new ForbiddenError(
        'User is not associated with an organization'
      );
    }

    const membership = user.memberships[0];

    return {
      id: user.id,
      name: user.name,
      email: user.email,
      phone: user.phone,
      role: membership.role,
      status: user.status,
      customerId: user.customerId,
      organizationId: membership.organizationId,
    };
  }

  async getCurrentUser(userId: string) {
    const user = await prisma.user.findUnique({
      where: {
        id: userId,
      },
      include: {
        memberships: {
          include: {
            organization: true,
          },
          orderBy: {
            createdAt: 'asc',
          },
        },
      },
    });

    if (!user) {
      throw new UnauthorizedError('User not found');
    }

    if (user.memberships.length === 0) {
      throw new ForbiddenError(
        'User is not associated with an organization'
      );
    }

    const membership = user.memberships[0];

    return {
      id: user.id,
      name: user.name,
      email: user.email,
      phone: user.phone,
      role: membership.role,
      status: user.status,
      customerId: user.customerId,
      memberships: user.memberships,
    };
  }
}