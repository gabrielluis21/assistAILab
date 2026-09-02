import {
  Role,
  UserStatus,
} from '@prisma/client';

import {
  prisma,
} from '../../core/database/prisma.js';

import type {
  AuthenticatedUser,
} from '../../core/middleware/auth.middleware.js';

import {
  ForbiddenError,
} from '../../core/utils/errors.js';

export async function authorizeFinanceCoreMutationLive(
  user: AuthenticatedUser
): Promise<string> {
  if (
    ![
      'ADMIN',
      'TECHNICIAN',
    ].includes(
      user.role
    ) ||
    !user.organizationId
  ) {
    throw new ForbiddenError(
      'Current Finance Core authorization is required'
    );
  }

  const [
    currentUser,
    membership,
  ] =
    await Promise.all([
      prisma.user.findUnique({
        where: {
          id:
            user.sub,
        },
        select: {
          status:
            true,
        },
      }),

      prisma.membership.findUnique({
        where: {
          userId_organizationId: {
            userId:
              user.sub,
            organizationId:
              user.organizationId,
          },
        },
        select: {
          role:
            true,
        },
      }),
    ]);

  if (
    !currentUser ||
    currentUser.status !==
      UserStatus.ACTIVE
  ) {
    throw new ForbiddenError(
      'Finance Core mutation requires an ACTIVE user'
    );
  }

  if (
    !membership ||
    (
      membership.role !==
        Role.ADMIN &&
      membership.role !==
        Role.TECHNICIAN
    )
  ) {
    throw new ForbiddenError(
      'Current organization membership is required for Finance Core mutation'
    );
  }

  /**
   * Reject stale role-bearing JWTs.
   */
  if (
    membership.role !==
    user.role
  ) {
    throw new ForbiddenError(
      'Finance Core authorization changed; re-authentication is required'
    );
  }

  return user.organizationId;
}
export async function authorizeFinanceCustomerMutationLive(
  user: AuthenticatedUser
): Promise<string> {
  if (
    user.role !==
      'CUSTOMER' ||
    !user.customerId
  ) {
    throw new ForbiddenError(
      'Current CUSTOMER Finance Core authorization is required'
    );
  }

  const currentUser =
    await prisma
      .user
      .findUnique({
        where: {
          id:
            user.sub,
        },

        select: {
          role:
            true,

          status:
            true,

          customerId:
            true,
        },
      });

  if (
    !currentUser ||
    currentUser.status !==
      UserStatus.ACTIVE ||
    currentUser.role !==
      Role.CUSTOMER ||
    currentUser.customerId !==
      user.customerId
  ) {
    throw new ForbiddenError(
      'Current CUSTOMER identity is required for Finance Core mutation'
    );
  }

  return user.customerId;
}
