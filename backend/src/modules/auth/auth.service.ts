import bcrypt from 'bcrypt';

import {
  Role,
  UserStatus,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import {
  RegisterInput,
  LoginInput,
} from './auth.schema.js';

import {
  UnauthorizedError,
  ForbiddenError,
  ConflictError,
} from '../../core/utils/errors.js';

import type {
  AuthenticatedUser,
} from '../../core/middleware/auth.middleware.js';

const SALT_ROUNDS =
  12;

export class AuthService {
  async register(
    input: RegisterInput
  ) {
    const existingUser =
      await prisma
        .user
        .findUnique({
          where: {
            email:
              input.email,
          },
        });

    if (existingUser) {
      throw new ConflictError(
        'A user with this email already exists'
      );
    }

    const passwordHash =
      await bcrypt.hash(
        input.password,
        SALT_ROUNDS
      );

    return prisma
      .$transaction(
        async (tx) => {
          const customer =
            await tx
              .customer
              .create({
                data: {
                  name:
                    input.name,

                  email:
                    input.email,

                  phone:
                    input.phone,
                },
              });

          const user =
            await tx
              .user
              .create({
                data: {
                  name:
                    input.name,

                  email:
                    input.email,

                  phone:
                    input.phone,

                  passwordHash,

                  role:
                    'CUSTOMER',

                  status:
                    'PENDING',

                  customerId:
                    customer.id,
                },
              });

          return {
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
          };
        }
      );
  }

  async validateCredentials(
    input: LoginInput
  ) {
    const user =
      await prisma
        .user
        .findUnique({
          where: {
            email:
              input.email,
          },

          include: {
            memberships: {
              orderBy: {
                createdAt: 'asc',
              },
            },
          },
        });

    if (!user) {
      throw new UnauthorizedError(
        'Invalid credentials'
      );
    }

    if (
      user.status !==
      'ACTIVE'
    ) {
      throw new ForbiddenError(
        'User account is not active'
      );
    }

    const valid =
      await bcrypt.compare(
        input.password,
        user.passwordHash
      );

    if (!valid) {
      throw new UnauthorizedError(
        'Invalid credentials'
      );
    }

    /**
     * ======================================================
     * CUSTOMER
     * ======================================================
     *
     * Customer é identidade global.
     *
     * NÃO exige Membership.
     */
    if (
      user.role ===
      'CUSTOMER'
    ) {
      if (!user.customerId) {
        throw new ForbiddenError(
          'CUSTOMER user has no associated Customer identity'
        );
      }

      return {
        id:
          user.id,

        name:
          user.name,

        email:
          user.email,

        phone:
          user.phone,

        role:
          'CUSTOMER',

        status:
          user.status,

        customerId:
          user.customerId,

        organizationId:
          null,
      };
    }

    /**
     * ======================================================
     * ADMIN / TECHNICIAN
     * ======================================================
     *
     * AUTH-BE-01 strict issuer coherence:
     * a professional credential must not carry Customer identity.
     */
    if (
      user.customerId !==
      null
    ) {
      throw new ForbiddenError(
        'Professional user has invalid Customer identity binding'
      );
    }

    if (
      user.memberships.length ===
      0
    ) {
      throw new ForbiddenError(
        'User is not associated with an organization'
      );
    }

    const membership =
      user.memberships[0];

    if (
      membership.role ===
      Role.CUSTOMER
    ) {
      throw new ForbiddenError(
        'Professional Membership role is invalid'
      );
    }

    return {
      id:
        user.id,

      name:
        user.name,

      email:
        user.email,

      phone:
        user.phone,

      role:
        membership.role,

      status:
        user.status,

      customerId:
        user.customerId,

      organizationId:
        membership.organizationId,
    };
  }

  /**
   * Returns the current user without re-selecting an arbitrary effective
   * Membership.
   *
   * The exact security scope has already been validated by authenticate().
   * memberships[] remains informational and preserves the existing response
   * contract; role / organizationId are derived only from the JWT-bound
   * Membership.
   */
  async getCurrentUser(
    authUser:
      AuthenticatedUser
  ) {
    const user =
      await prisma
        .user
        .findUnique({
          where: {
            id:
              authUser.sub,
          },

          include: {
            customer: {
              select: {
                id:
                  true,
              },
            },

            memberships: {
              include: {
                organization:
                  true,
              },

              orderBy: {
                createdAt:
                  'asc',
              },
            },
          },
        });

    if (
      !user ||
      user.status !==
        UserStatus.ACTIVE
    ) {
      throw new ForbiddenError(
        'AUTHORITY_REAUTH_REQUIRED'
      );
    }

    if (
      authUser.role ===
      'CUSTOMER'
    ) {
      if (
        user.role !==
          Role.CUSTOMER ||
        !user.customerId ||
        user.customerId !==
          authUser.customerId ||
        !user.customer ||
        user.customer.id !==
          authUser.customerId
      ) {
        throw new ForbiddenError(
          'AUTHORITY_REAUTH_REQUIRED'
        );
      }

      return {
        id:
          user.id,

        name:
          user.name,

        email:
          user.email,

        phone:
          user.phone,

        role:
          Role.CUSTOMER,

        status:
          user.status,

        customerId:
          user.customerId,

        organizationId:
          null,

        memberships:
          user.memberships,
      };
    }

    const organizationId =
      authUser.organizationId;

    if (
      !organizationId ||
      user.role ===
        Role.CUSTOMER ||
      user.customerId !==
        null
    ) {
      throw new ForbiddenError(
        'AUTHORITY_REAUTH_REQUIRED'
      );
    }

    const membership =
      user.memberships
        .find(
          (
            item
          ) =>
            item.organizationId ===
            organizationId
        );

    if (
      !membership ||
      membership.role !==
        authUser.role
    ) {
      throw new ForbiddenError(
        'AUTHORITY_REAUTH_REQUIRED'
      );
    }

    return {
      id:
        user.id,

      name:
        user.name,

      email:
        user.email,

      phone:
        user.phone,

      role:
        membership.role,

      status:
        user.status,

      customerId:
        null,

      organizationId,

      memberships:
        user.memberships,
    };
  }

}
