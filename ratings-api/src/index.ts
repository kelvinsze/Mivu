import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { Env } from './types/env';
import { healthRoutes } from './routes/health';
import { ratingsRoutes } from './routes/ratings';
import { adminRoutes } from './routes/admin';
import { rateLimitMiddleware } from './middleware/rate-limit';
import { createErrorResponse } from './utils/response';
import { logger } from './utils/logger';

const app = new Hono<{ Bindings: Env }>();

// Security & CORS
app.use('*', cors({
  origin: '*',
  allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
  allowHeaders: ['Content-Type', 'Authorization'],
  maxAge: 86400,
}));

// Client Rate Limiting (Section 20: 60 req/min/IP)
app.use('/v1/*', rateLimitMiddleware(60, 60000));

// Mount Routes
app.route('/', healthRoutes);
app.route('/', ratingsRoutes);
app.route('/', adminRoutes);

// 404 Handler
app.notFound((c) => {
  return createErrorResponse('NOT_FOUND', `Route not found: ${c.req.method} ${c.req.path}`, 404);
});

// Global Error Handler
app.onError((err, c) => {
  logger.error('unhandled_error', {
    message: err.message,
    path: c.req.path,
    method: c.req.method,
  });

  return createErrorResponse('INTERNAL_ERROR', 'An unexpected internal server error occurred', 500);
});

export default app;
