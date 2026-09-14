import { Context, Next } from 'hono';
import { Env } from '../types/env';
import { createErrorResponse } from '../utils/response';

/**
 * Middleware to verify Bearer token against APP_API_KEY.
 * @param required If true, always fails if APP_API_KEY is not set or token doesn't match.
 *                 If false, allows request when APP_API_KEY is not configured (optional auth).
 */
export function authMiddleware(required: boolean = true) {
  return async (c: Context<{ Bindings: Env }>, next: Next) => {
    const appApiKey = c.env.APP_API_KEY?.trim();

    if (!appApiKey) {
      if (required) {
        return createErrorResponse('SERVER_CONFIG_ERROR', 'APP_API_KEY is not configured on server', 500);
      }
      // Public / development mode without key
      return next();
    }

    const authHeader = c.req.header('Authorization');
    if (!authHeader) {
      return createErrorResponse('UNAUTHORIZED', 'Missing Authorization header with Bearer token', 401);
    }

    const match = authHeader.match(/^Bearer\s+(.+)$/i);
    if (!match || match[1].trim() !== appApiKey) {
      return createErrorResponse('UNAUTHORIZED', 'Invalid authorization token', 401);
    }

    return next();
  };
}
