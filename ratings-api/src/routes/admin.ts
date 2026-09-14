import { Hono } from 'hono';
import { Env, MediaType } from '../types/env';
import { authMiddleware } from '../middleware/auth';
import { createErrorResponse, createJsonResponse } from '../utils/response';
import { IdentityService } from '../services/identity';
import { CacheService } from '../services/cache';
import { isValidImdbId, isValidMediaType, parsePositiveInteger } from '../utils/validation';

export const adminRoutes = new Hono<{ Bindings: Env }>();

// All admin routes require Bearer APP_API_KEY
adminRoutes.use('*', authMiddleware(true));

/**
 * Administrative manual Douban mapping (Section 32)
 * PUT /v1/admin/identity/douban
 * Body: { "imdb": "tt0903747", "douban": "2131459" }
 */
adminRoutes.put('/v1/admin/identity/douban', async (c) => {
  let body: Record<string, unknown>;
  try {
    body = await c.req.json();
  } catch {
    return createErrorResponse('INVALID_JSON', 'Request body must be valid JSON', 400);
  }

  const doubanId = typeof body.douban === 'string' || typeof body.douban === 'number' ? String(body.douban).trim() : '';
  if (!doubanId || !/^\d+$/.test(doubanId)) {
    return createErrorResponse('INVALID_DOUBAN_ID', 'Douban ID must be numeric string', 400);
  }

  const imdb = typeof body.imdb === 'string' ? body.imdb.trim() : undefined;
  const tmdb = parsePositiveInteger(body.tmdb);
  const type = typeof body.type === 'string' && isValidMediaType(body.type) ? (body.type as MediaType) : undefined;

  if (!imdb && !tmdb) {
    return createErrorResponse('MISSING_IDENTIFIER', 'Either imdb or tmdb ID must be provided', 400);
  }

  if (imdb && !isValidImdbId(imdb)) {
    return createErrorResponse('INVALID_IMDB_ID', 'Invalid IMDb ID format', 400);
  }

  if (body.tmdb !== undefined && tmdb === undefined) {
    return createErrorResponse('INVALID_TMDB_ID', 'Invalid TMDb ID format', 400);
  }

  try {
    const updated = await IdentityService.setManualDoubanMapping(
      c.env.DB,
      {
        imdb,
        tmdb,
        type,
      },
      doubanId
    );

    // Invalidate old cache for this identity
    if (updated.id) {
      await CacheService.invalidate(c.env.DB, updated.id);
    }

    return createJsonResponse({
      success: true,
      identity: updated,
    });
  } catch (err: unknown) {
    return createErrorResponse('UPDATE_FAILED', String(err), 500);
  }
});

/**
 * Administrative cache invalidation
 * DELETE /v1/admin/cache
 * Body: { "imdb": "tt0903747" }
 */
adminRoutes.delete('/v1/admin/cache', async (c) => {
  let body: Record<string, unknown>;
  try {
    body = await c.req.json();
  } catch {
    return createErrorResponse('INVALID_JSON', 'Request body must be valid JSON', 400);
  }

  const imdb = typeof body.imdb === 'string' ? body.imdb.trim() : undefined;
  const tmdb = parsePositiveInteger(body.tmdb);
  const type = typeof body.type === 'string' && isValidMediaType(body.type) ? (body.type as MediaType) : undefined;

  if (!imdb && !tmdb) {
    return createErrorResponse('MISSING_IDENTIFIER', 'Either imdb or tmdb ID must be provided', 400);
  }

  if (body.tmdb !== undefined && tmdb === undefined) {
    return createErrorResponse('INVALID_TMDB_ID', 'Invalid TMDb ID format', 400);
  }

  try {
    const identity = await IdentityService.resolveIdentity(c.env.DB, { imdb, tmdb, type });
    if (identity.id) {
      await CacheService.invalidate(c.env.DB, identity.id);
    }

    return createJsonResponse({ success: true, message: 'Cache invalidated' });
  } catch (err: unknown) {
    return createErrorResponse('INVALIDATE_FAILED', String(err), 500);
  }
});
