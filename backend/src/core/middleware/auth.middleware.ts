import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import {
  ForbiddenError,
} from '../utils/errors.js';

export interface AuthenticatedUser {
  sub: string;
  role: string;
  name: string;
  customerId: string | null;

  /**
   * ADMIN / TECHNICIAN:
   * obrigatório e derivado da Membership.
   *
   * CUSTOMER:
   * null, pois a identidade é global.
   */
  organizationId: string | null;
}

export function getAuthUser(
  request: FastifyRequest
): AuthenticatedUser {
  return (request as any)
    .user as AuthenticatedUser;
}

/**
 * Use em operações que obrigatoriamente
 * acontecem dentro de uma Organization.
 */
export function requireOrganizationId(
  user: AuthenticatedUser
): string {
  if (!user.organizationId) {
    throw new ForbiddenError(
      'Organization context is required'
    );
  }

  return user.organizationId;
}

export async function authenticate(
  request: FastifyRequest,
  reply: FastifyReply
) {
  try {
    await request.jwtVerify();
  } catch {
    return reply
      .status(401)
      .send({
        error: 'Unauthorized',
      });
  }
}

export function authorize(
  allowedRoles: string[]
) {
  return async (
    request: FastifyRequest,
    reply: FastifyReply
  ) => {
    const user =
      getAuthUser(request);

    if (
      !user ||
      !user.role
    ) {
      return reply
        .status(401)
        .send({
          error: 'Unauthorized',
        });
    }

    if (
      !allowedRoles.includes(
        user.role
      )
    ) {
      return reply
        .status(403)
        .send({
          error:
            'Forbidden: Insufficient privileges',
        });
    }
  };
}