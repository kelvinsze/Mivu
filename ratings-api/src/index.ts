import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { Env } from './types/env';
import { healthRoutes } from './routes/health';
import { ratingsRoutes } from './routes/ratings';
import { adminRoutes } from './routes/admin';
import { rateLimitMiddleware } from './middleware/rate-limit';
import { createErrorResponse } from './utils/response';
import { logger } from './utils/logger';
import { appAttestRoutes } from './routes/app-attest';

const app = new Hono<{ Bindings: Env }>();

// Security & CORS: restrict admin routes to ADMIN_CORS_ORIGIN, wildcard for public APIs
app.use('*', async (c, next) => {
  if (c.req.path.startsWith('/v1/admin/')) {
    const adminOrigin = c.env.ADMIN_CORS_ORIGIN || 'https://admin.koldllc.com';
    return cors({
      origin: (origin) => (origin === adminOrigin ? origin : null),
      allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
      allowHeaders: ['Content-Type', 'Authorization'],
      maxAge: 86400,
    })(c, next);
  }
  return cors({
    origin: '*',
    allowMethods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowHeaders: ['Content-Type', 'Authorization'],
    maxAge: 86400,
  })(c, next);
});

// Client Rate Limiting (Section 20: 60 req/min/IP)
app.use('/v1/*', rateLimitMiddleware(60, 60000));

// Mount Routes
app.route('/', healthRoutes);
app.route('/', ratingsRoutes);
app.route('/', appAttestRoutes);
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

const worker = Object.assign(app, {
  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    logger.info('cron_cleanup_started', { scheduledTime: event.scheduledTime });
    try {
      const result = await env.DB.prepare(
        'DELETE FROM app_attest_challenges WHERE expires_at < unixepoch()'
      ).run();
      logger.info('cron_cleanup_completed', { deletedRows: result.meta?.changes ?? 0 });
    } catch (err) {
      logger.error('cron_cleanup_failed', { message: err instanceof Error ? err.message : String(err) });
    }
  },
});

export default worker;
