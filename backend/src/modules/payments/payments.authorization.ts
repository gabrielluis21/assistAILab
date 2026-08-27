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

type LivePaymentPrincipal = {
  organizationId: string;
  membershipRole: Role;
};

function requireJwtStaffRole(
  user: AuthenticatedUser
): asserts user is AuthenticatedUser & {
  role: 'ADMIN' | 'TECHNICIAN';
  organizationId: string;
} {
  if (
    ![
      'ADMIN',
      'TECHNICIAN',
    ].includes(user.role) ||
    !user.organizationId
  ) {
    throw new ForbiddenError(
      'Current financial authorization is required'
    );
  }
}

async function loadLivePrincipal(
  user: AuthenticatedUser
): Promise<LivePaymentPrincipal> {
  requireJwtStaffRole(user);

  const [
    currentUser,
    membership,
  ] = await Promise.all([
    prisma.user.findUnique({
      where: {
        id: user.sub,
      },
      select: {
        status: true,
      },
    }),

    prisma.membership.findUnique({
      where: {
        userId_organizationId: {
          userId: user.sub,
          organizationId:
            user.organizationId,
        },
      },
      select: {
        role: true,
      },
    }),
  ]);

  if (
    !currentUser ||
    currentUser.status !== UserStatus.ACTIVE
  ) {
    throw new ForbiddenError(
      'Financial access requires an ACTIVE user'
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
      'Current organization membership is required for financial access'
    );
  }

  return {
    organizationId:
      user.organizationId,
    membershipRole:
      membership.role,
  };
}

export async function authorizePaymentReadLive(
  user: AuthenticatedUser
): Promise<string> {
  const principal =
    await loadLivePrincipal(user);

  return principal.organizationId;
}

/**
 * Financial mutations reject a stale role-bearing token when the
 * current Membership role changed after token issuance.
 */
export async function authorizePaymentMutationLive(
  user: AuthenticatedUser
): Promise<string> {
  const principal =
    await loadLivePrincipal(user);

  if (
    principal.membershipRole !== user.role
  ) {
    throw new ForbiddenError(
      'Financial authorization changed; re-authentication is required'
    );
  }

  return principal.organizationId;
}

/**
 * Admin-sensitive financial operations require BOTH JWT ADMIN
 * and current Membership ADMIN.
 */
export async function authorizePaymentAdminLive(
  user: AuthenticatedUser
): Promise<string> {
  if (user.role !== 'ADMIN') {
    throw new ForbiddenError(
      'ADMIN role is required'
    );
  }

  const principal =
    await loadLivePrincipal(user);

  if (
    principal.membershipRole !== Role.ADMIN
  ) {
    throw new ForbiddenError(
      'Current ADMIN membership is required'
    );
  }

  return principal.organizationId;
}
