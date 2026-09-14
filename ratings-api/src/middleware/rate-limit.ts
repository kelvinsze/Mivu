import { Context, Next } from 'hono';
import { Env } from '../types/env';
import { createErrorResponse } from '../utils/response';

interface RateLimitRecord {
  count: number;
  resetAt: number;
}

const clientIpRecords = new Map<string, RateLimitRecord>();

/**
 * Periodically cleans up expired records to prevent unbounded memory growth
 */
function cleanupExpiredRecords(): void {
  const now = Date.now();
  for (const [ip, record] of clientIpRecords.entries()) {
    if (now >= record.resetAt) {
      clientIpRecords.delete(ip);
    }
  }
}

export function rateLimitMiddleware(limit: number = 60, windowMs: number = 60000) {
  let lastCleanup = Date.now();

  return async (c: Context<{ Bindings: Env }>, next: Next) => {
    // In dev / tests allow skipping or disabling if desired
    if (c.env.ENVIRONMENT === 'test') {
      return next();
    }

    const now = Date.now();

    // Occasional cleanup
    if (now - lastCleanup > 30000) {
      cleanupExpiredRecords();
      lastCleanup = now;
    }

    // CF-Connecting-IP is set by Cloudflare at the edge. Do not trust
    // x-forwarded-for, which callers can spoof when reaching a local Worker.
    // This limiter is intentionally per-isolate; use KV/DO for global limits.
    const clientIp = c.req.header('cf-connecting-ip') || 'unknown-ip';

    let record = clientIpRecords.get(clientIp);

    if (!record || now >= record.resetAt) {
      record = {
        count: 1,
        resetAt: now + windowMs,
      };
      clientIpRecords.set(clientIp, record);
    } else {
      record.count += 1;
    }

    c.header('X-RateLimit-Limit', String(limit));
    c.header('X-RateLimit-Remaining', String(Math.max(0, limit - record.count)));
    c.header('X-RateLimit-Reset', String(Math.ceil(record.resetAt / 1000)));

    if (record.count > limit) {
      return createErrorResponse(
        'RATE_LIMIT_EXCEEDED',
        `Client rate limit exceeded. Max ${limit} requests per minute.`,
        429
      );
    }

    return next();
  };
}

export function clearRateLimits(): void {
  clientIpRecords.clear();
}
