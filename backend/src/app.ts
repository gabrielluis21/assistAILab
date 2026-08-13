import fastify from 'fastify';
import cors from '@fastify/cors';
import jwt from '@fastify/jwt';
import { healthRoutes } from './modules/health/health.routes.js';
import { syncRoutes } from './modules/sync/sync.routes.js';
import { customerRoutes } from './modules/customers/customers.routes.js';
import { serviceOrderRoutes } from './modules/service_orders/service_orders.routes.js';
import { authRoutes } from './modules/auth/auth.routes.js';
import { equipmentRoutes } from './modules/equipment/equipment.routes.js';
import { paymentsRoutes } from './modules/payments/payments.routes.js';
import { AppError } from './core/utils/errors.js';
import { authenticate, authorize } from './core/middleware/auth.middleware.js';

export function buildApp() {
  const app = fastify({
    logger: process.env.NODE_ENV === 'development',
  });

  const jwtSecret = process.env.JWT_SECRET;
  if (!jwtSecret) {
    throw new Error('FATAL: JWT_SECRET environment variable is missing. App startup aborted.');
  }

  // Plugins
  const isDev = process.env.NODE_ENV === 'development';
  const allowedOrigins = process.env.CORS_ALLOWED_ORIGINS
    ? process.env.CORS_ALLOWED_ORIGINS.split(',').map((s) => s.trim())
    : ['http://localhost:3000', 'http://127.0.0.1:3000'];

  app.register(cors, {
    origin: isDev ? true : allowedOrigins,
  });

  app.register(jwt, {
    secret: jwtSecret,
  });

  // Decorate authenticate and authorize helpers for protected routes
  app.decorate('authenticate', authenticate);
  app.decorate('authorize', authorize);

  // Routes
  app.register(healthRoutes);
  app.register(authRoutes, { prefix: '/api/v1/auth' });
  app.register(syncRoutes, { prefix: '/api/v1/sync' });
  app.register(customerRoutes, { prefix: '/api/v1/customers' });
  app.register(serviceOrderRoutes, { prefix: '/api/v1/service-orders' });
  app.register(equipmentRoutes, { prefix: '/api/v1/equipment' });
  app.register(paymentsRoutes, { prefix: '/api/v1/payments' });

  // Error Handler
  app.setErrorHandler((error, request, reply) => {
    if (error instanceof AppError) {
      return reply.status(error.statusCode).send({ error: error.message });
    }
    if (error.validation) {
      return reply.status(400).send({ error: 'Validation Error', details: error.validation });
    }
    app.log.error(error);
    return reply.status(500).send({ error: 'Internal Server Error' });
  });

  return app;
}
