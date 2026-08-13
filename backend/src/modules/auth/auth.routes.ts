import { FastifyInstance } from 'fastify';
import { registerHandler, loginHandler, meHandler } from './auth.controller.js';

export async function authRoutes(fastify: FastifyInstance) {
  fastify.post('/register', registerHandler);
  fastify.post('/login', loginHandler);

  // Protected: requires JWT verification
  fastify.get('/me', {
    preValidation: [(request, reply) => (fastify as any).authenticate(request, reply)],
    handler: meHandler,
  });
}
