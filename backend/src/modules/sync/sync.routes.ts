import { FastifyInstance } from 'fastify';
import { pushSyncHandler, pullSyncHandler, bootstrapSyncHandler } from './sync.controller.js';

export async function syncRoutes(fastify: FastifyInstance) {
  fastify.post('/bootstrap', { preValidation: [(fastify as any).authenticate] }, bootstrapSyncHandler);
  fastify.post('/push', { preValidation: [(fastify as any).authenticate] }, pushSyncHandler);
  fastify.get('/changes', { preValidation: [(fastify as any).authenticate] }, pullSyncHandler);
}
