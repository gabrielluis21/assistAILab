import { FastifyRequest, FastifyReply } from 'fastify';

/**
 * Usuário autenticado pelo JWT.
 *
 * organizationId representa a organização ativa do contexto
 * autenticado. Nunca deve ser recebido do cliente em operações
 * protegidas.
 */
export interface AuthenticatedUser {
  sub: string;
  role: string;
  name: string;
  customerId: string | null;
  organizationId: string;
}

/**
 * Retorna o usuário autenticado da requisição.
 */
export function getAuthUser(
  request: FastifyRequest
): AuthenticatedUser {
  return (request as any).user as AuthenticatedUser;
}

/**
 * Middleware de autenticação JWT.
 */
export async function authenticate(
  request: FastifyRequest,
  reply: FastifyReply
) {
  try {
    await request.jwtVerify();
  } catch {
    return reply.status(401).send({
      error: 'Unauthorized',
    });
  }
}

/**
 * Middleware de autorização por papel.
 */
export function authorize(allowedRoles: string[]) {
  return async (
    request: FastifyRequest,
    reply: FastifyReply
  ) => {
    const user = getAuthUser(request);

    if (!user || !user.role) {
      return reply.status(401).send({
        error: 'Unauthorized',
      });
    }

    if (!allowedRoles.includes(user.role)) {
      return reply.status(403).send({
        error: 'Forbidden: Insufficient privileges',
      });
    }
  };
}