import { FastifyRequest, FastifyReply } from 'fastify';
import { registerSchema, loginSchema } from './auth.schema.js';
import { AuthService } from './auth.service.js';

const authService = new AuthService();

export async function registerHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = registerSchema.parse(request.body);
  const user = await authService.register(body);
  return reply.status(201).send({ user });
}

export async function loginHandler(request: FastifyRequest, reply: FastifyReply) {
  const body = loginSchema.parse(request.body);
  const user = await authService.validateCredentials(body);

  // customerId is embedded in the JWT so controllers can enforce resource ownership
  // using req.user.customerId without trusting any client-supplied ID.
  const token = (request.server as any).jwt.sign(
    { sub: user.id, role: user.role, name: user.name, customerId: user.customerId ?? null },
    { expiresIn: '8h' }
  );

  return reply.send({ token, user });
}

export async function meHandler(request: FastifyRequest, reply: FastifyReply) {
  // This route will be protected by JWT verification middleware
  const user = (request as any).user;
  return reply.send({ user });
}
