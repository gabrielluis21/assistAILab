import {
  FastifyRequest,
  FastifyReply,
} from 'fastify';

import {
  ForbiddenError,
} from '../utils/errors.js';

import {
  AuthorityReauthenticationRequiredError,
  InvalidJwtAuthorityShapeError,
  resolveLiveAuthority,
  type ValidatedPrincipal,
} from '../auth/live_authority.service.js';

export type AuthenticatedUser =
  ValidatedPrincipal;

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

/**
 * AUTH-BE-01 central authority gate.
 *
 * request.user is only published to downstream authorization/controllers
 * after BOTH:
 *   1. cryptographic JWT verification; and
 *   2. live authority coherence validation.
 */
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

  try {
    const validatedPrincipal =
      await resolveLiveAuthority(
        (request as any)
          .user
      );

    (request as any)
      .user =
      validatedPrincipal;
  } catch (error) {
    if (
      error instanceof
      InvalidJwtAuthorityShapeError
    ) {
      return reply
        .status(401)
        .send({
          error:
            'Unauthorized',
        });
    }

    if (
      error instanceof
      AuthorityReauthenticationRequiredError
    ) {
      return reply
        .status(403)
        .send({
          error:
            'AUTHORITY_REAUTH_REQUIRED',
        });
    }

    throw error;
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
          error:
            'Unauthorized',
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
