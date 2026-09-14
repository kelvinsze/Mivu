import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { RatingsService } from '../src/services/ratings';
import { CacheService } from '../src/services/cache';
import { createMockD1Database } from './mock-d1';
import { Env } from '../src/types/env';
import { globalCircuitBreaker } from '../src/providers/circuit-breaker';

describe('Ratings Aggregation & Resilience Tests', () => {
  let db: D1Database;
  let env: Env;
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    db = createMockD1Database();
    env = {
      DB: db,
      MDBLIST_API_KEY: 'test-mdb-key',
      APP_API_KEY: 'test-app-key',
      ENVIRONMENT: 'test',
      DOUBAN_ENABLED: 'true',
      MDBLIST_ENABLED: 'true',
    };
    CacheService.clearL1();
    globalCircuitBreaker.reset();
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('aggregates both MDBList and Douban when both succeed', async () => {
    const mockMdb = {
      title: 'Breaking Bad',
      year: 2008,
      type: 'show',
      ratings: [
        { source: 'imdb', value: 9.5, votes: 2000000 },
        { source: 'tomatoes', value: 96 },
        { source: 'metacritic', value: 87 },
      ],
    };

    const mockDoubanHtml = `
      <meta itemprop="ratingValue" content="9.2">
      <meta itemprop="reviewCount" content="390000">
    `;

    globalThis.fetch = vi.fn().mockImplementation((url: string) => {
      if (url.includes('api.mdblist.com')) {
        return Promise.resolve(new Response(JSON.stringify(mockMdb), { status: 200 }));
      }
      if (url.includes('m.douban.com/search')) {
        return Promise.resolve(new Response('<a href="/movie/subject/2373195/" data-imdb-id="tt0903747">Breaking Bad</a>', { status: 200 }));
      }
      if (url.includes('m.douban.com/movie/subject/2373195')) {
        return Promise.resolve(new Response(mockDoubanHtml, { status: 200 }));
      }
      return Promise.reject(new Error('Unknown URL: ' + url));
    });

    const result = await RatingsService.getRatings(env, { imdb: 'tt0903747' });

    expect(result.status).toBe(200);
    expect(result.response.media.title).toBe('Breaking Bad');
    expect(result.response.ratings.imdb?.score).toBe(9.5);
    expect(result.response.ratings.rottenTomatoes?.critics).toBe(96);
    expect(result.response.ratings.douban?.score).toBe(9.2);
    expect(result.response.ratings.douban?.votes).toBe(390000);
    expect(result.response.ids.douban).toBe('2373195');
    const identityRow = (db as unknown as { identities: Array<{ douban_id: string | null; douban_match_source: string | null }> }).identities[0];
    expect(identityRow.douban_id).toBe('2373195');
    expect(identityRow.douban_match_source).toBe('auto');
  });

  it('retries a Douban miss after MDBList enriches the identity metadata', async () => {
    let imdbSearches = 0;
    globalThis.fetch = vi.fn().mockImplementation((url: string) => {
      if (url.includes('api.mdblist.com')) {
        return Promise.resolve(
          new Response(JSON.stringify({ title: 'The Matrix', year: 1999, ratings: [{ source: 'imdb', value: 8.7 }] }), {
            status: 200,
          })
        );
      }
      if (url.includes('m.douban.com/search')) {
        imdbSearches += 1;
        const html = imdbSearches === 1
          ? '<p>no result</p>'
          : '<a href="/movie/subject/1292052/" data-imdb-id="tt0133093">The Matrix</a>';
        return Promise.resolve(new Response(html, { status: 200 }));
      }
      return Promise.resolve(
        new Response('<meta itemprop="ratingValue" content="9.1"><meta itemprop="reviewCount" content="1000">', { status: 200 })
      );
    });

    const result = await RatingsService.getRatings(env, { imdb: 'tt0133093' });

    expect(result.status).toBe(200);
    expect(result.response.ratings.douban?.score).toBe(9.1);
    expect(imdbSearches).toBe(2);
  });

  it('returns partial data when Douban fails but MDBList succeeds', async () => {
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
      // Douban throws network error
      return Promise.reject(new Error('Douban connection failed'));
    });

    const result = await RatingsService.getRatings(env, { imdb: 'tt0903747' });

    expect(result.status).toBe(200);
    expect(result.response.ratings.imdb?.score).toBe(9.5);
    expect(result.response.ratings.douban).toBeNull();
  });

  it('second identical request hits cache and does not call fetch again', async () => {
    const fetchSpy = vi.fn().mockImplementation((url: string) => {
      if (url.includes('api.mdblist.com')) {
        return Promise.resolve(
          new Response(JSON.stringify({ title: 'Cached Movie', ratings: [{ source: 'imdb', value: 8.0 }] }), {
            status: 200,
          })
        );
      }
      return Promise.resolve(new Response('<meta itemprop="ratingValue" content="8.5">', { status: 200 }));
    });
    globalThis.fetch = fetchSpy;

    // First call (cache miss)
    const res1 = await RatingsService.getRatings(env, { imdb: 'tt1234567' });
    expect(res1.status).toBe(200);
    expect(res1.response.meta.cached).toBe(false);
    const initialFetchCount = fetchSpy.mock.calls.length;

    // Second call (cache hit!)
    const res2 = await RatingsService.getRatings(env, { imdb: 'tt1234567' });
    expect(res2.status).toBe(200);
    expect(res2.response.meta.cached).toBe(true);
    // Fetch should not have been called again
    expect(fetchSpy.mock.calls.length).toBe(initialFetchCount);
  });

  it('deduplicates concurrent first requests before identity creation', async () => {
    const fetchSpy = vi.fn().mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ title: 'Concurrent', ratings: [{ source: 'imdb', value: 8.1 }] }), { status: 200 }))
    );
    globalThis.fetch = fetchSpy;
    const requestEnv = { ...env, DOUBAN_ENABLED: 'false' };
    const results = await Promise.all([
      RatingsService.getRatings(requestEnv, { tmdb: 603, type: 'movie' }),
      RatingsService.getRatings(requestEnv, { tmdb: 603, type: 'movie' }),
    ]);

    expect(results[0].status).toBe(200);
    expect(results[1].status).toBe(200);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect((db as unknown as { identities: unknown[] }).identities).toHaveLength(1);
  });

  it('serves stale cached data when upstream providers fail', async () => {
    // 1. Prime cache with successful data
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ title: 'Stale Test', ratings: [{ source: 'imdb', value: 7.7 }] }), {
        status: 200,
      })
    );
    await RatingsService.getRatings(env, { imdb: 'tt7777777' });

    // Clear L1 to force check of D1
    CacheService.clearL1();

    // 2. Now upstream fails
    globalThis.fetch = vi.fn().mockRejectedValue(new Error('All upstream down'));

    const staleRes = await RatingsService.getRatings(env, { imdb: 'tt7777777' }, true);
    expect(staleRes.status).toBe(200);
    expect(staleRes.response.ratings.imdb?.score).toBe(7.7);
    expect(staleRes.response.meta.stale).toBe(true);
  });

  it('returns 502 Bad Gateway when all providers fail and no cache exists', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new Error('Network failure'));

    const result = await RatingsService.getRatings(env, { imdb: 'tt0000001' });
    expect(result.status).toBe(502);
  });

  it('returns 404 on a second request when both provider entries are negative-cached', async () => {
    const fetchSpy = vi.fn().mockResolvedValue(new Response('', { status: 404 }));
    globalThis.fetch = fetchSpy;

    const first = await RatingsService.getRatings(env, { imdb: 'tt0000099' });
    expect(first.status).toBe(404);
    const firstFetchCount = fetchSpy.mock.calls.length;

    const second = await RatingsService.getRatings(env, { imdb: 'tt0000099' });
    expect(second.status).toBe(404);
    expect(fetchSpy.mock.calls.length).toBe(firstFetchCount);
    expect(second.response.ratings.imdb).toBeNull();
  });

  it('synchronously refreshes entries older than the 30-day SWR window', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ title: 'Old Rating', ratings: [{ source: 'imdb', value: 7.1 }] }), { status: 200 })
    );
    await RatingsService.getRatings({ ...env, DOUBAN_ENABLED: 'false' }, { imdb: 'tt0000088' });

    const mock = db as unknown as { ratingsCache: Array<{ provider: string; fetched_at: string; expires_at: string }> };
    const old = new Date(Date.now() - 31 * 24 * 60 * 60 * 1000).toISOString();
    for (const row of mock.ratingsCache) {
      row.fetched_at = old;
      row.expires_at = old;
    }
    CacheService.clearL1();

    const fetchSpy = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ title: 'Fresh Rating', ratings: [{ source: 'imdb', value: 7.2 }] }), { status: 200 })
    );
    globalThis.fetch = fetchSpy;
    const refreshed = await RatingsService.getRatings({ ...env, DOUBAN_ENABLED: 'false' }, { imdb: 'tt0000088' });

    expect(refreshed.status).toBe(200);
    expect(refreshed.response.ratings.imdb?.score).toBe(7.2);
    expect(fetchSpy).toHaveBeenCalled();
  });
});
