export interface LogContext {
  event: string;
  identity?: string;
  cache?: 'hit' | 'miss' | 'stale';
  providers?: Record<string, string>;
  durationMs?: number;
  status?: number;
  error?: string;
  [key: string]: unknown;
}

const SENSITIVE_KEYS = ['apikey', 'api_key', 'mdblist_api_key', 'app_api_key', 'authorization', 'token', 'secret'];

function sanitizeObject(obj: unknown): unknown {
  if (!obj || typeof obj !== 'object') return obj;

  if (Array.isArray(obj)) {
    return obj.map(sanitizeObject);
  }

  const sanitized: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(obj as Record<string, unknown>)) {
    if (SENSITIVE_KEYS.some((sensitive) => key.toLowerCase().includes(sensitive))) {
      sanitized[key] = '[REDACTED]';
    } else if (typeof value === 'object' && value !== null) {
      sanitized[key] = sanitizeObject(value);
    } else if (typeof value === 'string' && value.toLowerCase().startsWith('bearer ')) {
      sanitized[key] = 'Bearer [REDACTED]';
    } else {
      sanitized[key] = value;
    }
  }
  return sanitized;
}

export const logger = {
  info(event: string, context: Omit<LogContext, 'event'> = {}): void {
    const payload = sanitizeObject({
      timestamp: new Date().toISOString(),
      level: 'info',
      event,
      ...context,
    });
    console.log(JSON.stringify(payload));
  },

  warn(event: string, context: Omit<LogContext, 'event'> = {}): void {
    const payload = sanitizeObject({
      timestamp: new Date().toISOString(),
      level: 'warn',
      event,
      ...context,
    });
    console.warn(JSON.stringify(payload));
  },

  error(event: string, context: Omit<LogContext, 'event'> = {}): void {
    const payload = sanitizeObject({
      timestamp: new Date().toISOString(),
      level: 'error',
      event,
      ...context,
    });
    console.error(JSON.stringify(payload));
  },
};
