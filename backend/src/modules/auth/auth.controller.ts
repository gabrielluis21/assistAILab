import { FastifyRequest, FastifyReply } from 'fastify';

import {
  registerSchema,
  loginSchema,
} from './auth.schema.js';

import { AuthService } from './auth.service.js';
import { getAuthUser } from '../../core/middleware/auth.middleware.js';

const authService = new AuthService();

export async function registerHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body = registerSchema.parse(request.body);

  const user = await authService.register(body);

  return reply.status(201).send({
    user,
  });
}

export async function loginHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const body = loginSchema.parse(request.body);

  const user = await authService.validateCredentials(body);

  const token = (request.server as any).jwt.sign(
    {
      sub: user.id,
      role: user.role,
      name: user.name,
      customerId: user.customerId ?? null,
      organizationId: user.organizationId,
    },
    {
      expiresIn: '8h',
    }
  );

  return reply.send({
    token,
    user,
  });
}

export async function meHandler(
  request: FastifyRequest,
  reply: FastifyReply
) {
  const authUser = getAuthUser(request);

  const user = await authService.getCurrentUser(
    authUser.sub
  );

  return reply.send({
    user,
  });
}