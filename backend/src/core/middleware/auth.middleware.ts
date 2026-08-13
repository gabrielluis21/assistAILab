import { FastifyRequest, FastifyReply } from 'fastify';

/**
 * Shape of the decoded JWT payload attached to request.user after jwtVerify().
 * customerId is non-null only for users with role === 'CUSTOMER'.
 */
export interface AuthenticatedUser {
  sub: string;       // userId
  role: string;      // ADMIN | TECHNICIAN | CUSTOMER
  name: string;
  customerId: string | null;
}

/**
 * Type-safe accessor for the authenticated user on a request.
 * Always use this instead of casting (request as any).user.
 */
export function getAuthUser(request: FastifyRequest): AuthenticatedUser {
  return (request as any).user as AuthenticatedUser;
}

export async function authenticate(request: FastifyRequest, reply: FastifyReply) {
  try {
    await request.jwtVerify();
  } catch (err) {
    return reply.status(401).send({ error: 'Unauthorized' });
  }
}

export function authorize(allowedRoles: string[]) {
  return async (request: FastifyRequest, reply: FastifyReply) => {
    const user = (request as any).user;
    if (!user || !user.role) {
      return reply.status(401).send({ error: 'Unauthorized' });
    }
    if (!allowedRoles.includes(user.role)) {
      return reply.status(403).send({ error: 'Forbidden: Insufficient privileges' });
    }
  };
}
