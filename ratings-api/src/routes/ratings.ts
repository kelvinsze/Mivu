import { Hono } from 'hono';
import { Env } from '../types/env';
import { validateRatingsQuery } from '../utils/validation';
import { createErrorResponse, createJsonResponse } from '../utils/response';
import { RatingsService } from '../services/ratings';
import { authMiddleware } from '../middleware/auth';
import { logger } from '../utils/logger';

export const ratingsRoutes = new Hono<{ Bindings: Env }>();

/**
 * Public ratings endpoint (Section 3)
 * Example:
 * GET /v1/ratings?imdb=tt0903747
 * GET /v1/ratings?tmdb=1396&type=tv
 * GET /v1/ratings?tmdb=278&type=movie
 */
function getExecutionContext(c: { executionCtx?: unknown }): { waitUntil?: (promise: Promise<unknown>) => void } | undefined {
  try {
    return (c as { executionCtx?: { waitUntil?: (p: Promise<unknown>) => void } }).executionCtx;
  } catch {
    return undefined;
  }
}

// Public when APP_API_KEY is unset; private/test deployments require Bearer.
ratingsRoutes.get('/v1/ratings', authMiddleware(false), async (c) => {
  const query = c.req.query();
  const validation = validateRatingsQuery({
    imdb: query.imdb,
    tmdb: query.tmdb,
    tvdb: query.tvdb,
    type: query.type,
  });

  if (!validation.valid || !validation.data) {
    return createErrorResponse(
      validation.error?.code || 'INVALID_REQUEST',
      validation.error?.message || 'Invalid request parameters',
      400
    );
  }

  try {
    const result = await RatingsService.getRatings(c.env, validation.data, false, getExecutionContext(c));
    return createJsonResponse(result.response, result.status);
  } catch (err: unknown) {
    logger.error('ratings_route_error', { error: err instanceof Error ? err.stack : String(err) });
    return createErrorResponse('INTERNAL_ERROR', 'An unexpected error occurred while fetching ratings', 500);
  }
});

/**
 * Protected force refresh endpoint (Section 31)
 * Example:
 * POST /v1/ratings/refresh
 * Body: { "imdb": "tt0903747" }
 */
ratingsRoutes.post('/v1/ratings/refresh', authMiddleware(true), async (c) => {
  let body: Record<string, unknown>;
  try {
    body = await c.req.json();
  } catch {
    return createErrorResponse('INVALID_JSON', 'Request body must be valid JSON', 400);
  }

  const validation = validateRatingsQuery({
    imdb: typeof body.imdb === 'string' ? body.imdb : undefined,
    tmdb: typeof body.tmdb === 'number' || typeof body.tmdb === 'string' ? String(body.tmdb) : undefined,
    tvdb: typeof body.tvdb === 'number' || typeof body.tvdb === 'string' ? String(body.tvdb) : undefined,
    type: typeof body.type === 'string' ? body.type : undefined,
  });

  if (!validation.valid || !validation.data) {
    return createErrorResponse(
      validation.error?.code || 'INVALID_REQUEST',
      validation.error?.message || 'Invalid request parameters',
      400
    );
  }

  try {
    const result = await RatingsService.getRatings(c.env, validation.data, true, getExecutionContext(c));
    return createJsonResponse(result.response, result.status);
  } catch (err: unknown) {
    return createErrorResponse('INTERNAL_ERROR', 'An unexpected error occurred while refreshing ratings', 500);
  }
});
