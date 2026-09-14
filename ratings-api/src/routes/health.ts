import { Hono } from 'hono';
import { Env } from '../types/env';
import { globalCircuitBreaker } from '../providers/circuit-breaker';
import { createJsonResponse } from '../utils/response';

export const healthRoutes = new Hono<{ Bindings: Env }>();

/**
 * Public health check endpoint (Section 30)
 * Does NOT make upstream provider calls.
 */
healthRoutes.get('/health', (c) => {
  return createJsonResponse({ status: 'ok' });
});

/**
 * Protected debug endpoint to inspect provider and circuit breaker status
 */
healthRoutes.get('/health/providers', (c) => {
  const appApiKey = c.env.APP_API_KEY?.trim();
  if (appApiKey) {
    const auth = c.req.header('Authorization');
    if (auth !== `Bearer ${appApiKey}`) {
      return createJsonResponse({ error: 'Unauthorized' }, 401);
    }
  }

  return createJsonResponse({
    status: 'ok',
    environment: c.env.ENVIRONMENT || 'development',
    providers: {
      mdblist: {
        enabled: c.env.MDBLIST_ENABLED !== 'false',
        circuitBreakerOpen: globalCircuitBreaker.isOpen('mdblist'),
        apiKeyConfigured: !!c.env.MDBLIST_API_KEY,
      },
      douban: {
        enabled: c.env.DOUBAN_ENABLED !== 'false',
        circuitBreakerOpen: globalCircuitBreaker.isOpen('douban'),
      },
    },
  });
});
