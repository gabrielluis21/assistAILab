import { FastifyInstance } from 'fastify';
import { pushSyncHandler, pullSyncHandler } from './sync.controller.js';

export async function syncRoutes(fastify: FastifyInstance) {
  fastify.post('/push', { preValidation: [(fastify as any).authenticate] }, pushSyncHandler);
  fastify.get('/changes', { preValidation: [(fastify as any).authenticate] }, pullSyncHandler);
}
