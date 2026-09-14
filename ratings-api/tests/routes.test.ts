import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import app from '../src/index';
import { createMockD1Database } from './mock-d1';
import { CacheService } from '../src/services/cache';
import { clearRateLimits } from '../src/middleware/rate-limit';

describe('App Routes End-to-End Tests', () => {
  let db: D1Database;
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    db = createMockD1Database();
    CacheService.clearL1();
    clearRateLimits();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('GET /health returns 200 ok', async () => {
    const res = await app.request('/health');
    expect(res.status).toBe(200);
    const json = await res.json();
    expect(json).toEqual({ status: 'ok' });
  });

  it('GET /v1/ratings rejects missing identifier with 400', async () => {
    const res = await app.request('/v1/ratings', {}, { DB: db });
    expect(res.status).toBe(400);
    const json = (await res.json()) as { error: { code: string; message: string } };
    expect(json.error.code).toBe('MISSING_IDENTIFIER');
  });

  it('GET /v1/ratings returns normalized response for valid query', async () => {
    const mockMdb = {
      title: 'Breaking Bad',
      year: 2008,
      type: 'show',
      ratings: [{ source: 'imdb', value: 9.5 }],
    };

    globalThis.fetch = vi.fn().mockImplementation((url: string) => {
      if (url.includes('api.mdblist.com')) {
        return Promise.resolve(new Response(JSON.stringify(mockMdb), { status: 200 }));
      }
      return Promise.resolve(new Response('', { status: 404 }));
    });

    const res = await app.request(
      '/v1/ratings?imdb=tt0903747',
      {
        headers: { Authorization: 'Bearer test-secret' },
      },
      {
        DB: db,
        MDBLIST_API_KEY: 'test-key',
        APP_API_KEY: 'test-secret',
        DOUBAN_ENABLED: 'false',
        MDBLIST_ENABLED: 'true',
      }
    );

    expect(res.status).toBe(200);
    const json = (await res.json()) as { media: { title: string }; ratings: { imdb: { score: number } } };
    expect(json.media.title).toBe('Breaking Bad');
    expect(json.ratings.imdb.score).toBe(9.5);
  });

  it('GET /v1/ratings is public when APP_API_KEY is unset', async () => {
    const res = await app.request('/v1/ratings?imdb=tt0903747', {}, { DB: db, DOUBAN_ENABLED: 'false' });
    expect(res.status).not.toBe(401);
  });

  it('GET /v1/ratings requires Bearer authorization when APP_API_KEY is set', async () => {
    const res = await app.request('/v1/ratings?imdb=tt0903747', {}, { DB: db, APP_API_KEY: 'test-secret' });
    expect(res.status).toBe(401);
  });

  it('admin rejects non-integer TMDb identifiers', async () => {
    const res = await app.request('/v1/admin/cache', {
      method: 'DELETE',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer admin-key' },
      body: JSON.stringify({ tmdb: '1abc', type: 'movie' }),
    }, { DB: db, APP_API_KEY: 'admin-key' });
    expect(res.status).toBe(400);
  });

  it('POST /v1/ratings/refresh requires Bearer authorization', async () => {
    // 1. Without Auth
    const resNoAuth = await app.request(
      '/v1/ratings/refresh',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ imdb: 'tt0903747' }),
      },
      { DB: db, APP_API_KEY: 'secret123' }
    );
    expect(resNoAuth.status).toBe(401);

    // 2. With Wrong Auth
    const resWrongAuth = await app.request(
      '/v1/ratings/refresh',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer wrong-key',
        },
        body: JSON.stringify({ imdb: 'tt0903747' }),
      },
      { DB: db, APP_API_KEY: 'secret123' }
    );
    expect(resWrongAuth.status).toBe(401);

    // 3. With Valid Auth
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ title: 'Breaking Bad', ratings: [{ source: 'imdb', value: 9.5 }] }), {
        status: 200,
      })
    );

    const resValidAuth = await app.request(
      '/v1/ratings/refresh',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer secret123',
        },
        body: JSON.stringify({ imdb: 'tt0903747' }),
      },
      {
        DB: db,
        APP_API_KEY: 'secret123',
        MDBLIST_API_KEY: 'mdb123',
        DOUBAN_ENABLED: 'false',
      }
    );
    expect(resValidAuth.status).toBe(200);
  });

  it('PUT /v1/admin/identity/douban sets manual mapping with confidence 1.0', async () => {
    const res = await app.request(
      '/v1/admin/identity/douban',
      {
        method: 'PUT',
        headers: {
          'Content-Type': 'application/json',
          Authorization: 'Bearer admin-key',
        },
        body: JSON.stringify({
          imdb: 'tt0903747',
          douban: '2131459',
        }),
      },
      { DB: db, APP_API_KEY: 'admin-key' }
    );

    expect(res.status).toBe(200);
    const json = (await res.json()) as {
      success: boolean;
      identity: { doubanId: string; doubanMatchConfidence: number; doubanMatchSource: string };
    };
    expect(json.success).toBe(true);
    expect(json.identity.doubanId).toBe('2131459');
    expect(json.identity.doubanMatchConfidence).toBe(1.0);
    expect(json.identity.doubanMatchSource).toBe('manual');
  });

  it('enforces rate limit of 60 requests per minute', async () => {
    const env = {
      DB: db,
      ENVIRONMENT: 'production',
    };

    const headers = { 'cf-connecting-ip': '198.51.100.1' };

    // Send 60 requests
    for (let i = 0; i < 60; i++) {
      const res = await app.request('/v1/ratings?imdb=tt0000000', { headers }, env);
      expect(res.status).not.toBe(429);
    }

    // 61st request should be rate limited with 429
    const limitedRes = await app.request('/v1/ratings?imdb=tt0000000', { headers }, env);
    expect(limitedRes.status).toBe(429);
    const json = (await limitedRes.json()) as { error: { code: string } };
    expect(json.error.code).toBe('RATE_LIMIT_EXCEEDED');
  });
});
