import { describe, it, expect, beforeEach } from 'vitest';
import { CacheService } from '../src/services/cache';
import { createMockD1Database } from './mock-d1';
import { NormalizedRatingsResponse } from '../src/types/env';

describe('CacheService Unit Tests', () => {
  let db: D1Database;
  const cacheStore = new Map<string, Response>();
  const cache = {
    async match(request: Request) {
      const response = cacheStore.get(request.url);
      return response ? response.clone() : undefined;
    },
    async put(request: Request, response: Response) {
      cacheStore.set(request.url, response.clone());
    },
    async delete(request: Request) {
      return cacheStore.delete(request.url);
    },
  } as unknown as Cache;

  const mockResponse: NormalizedRatingsResponse = {
    media: { type: 'movie', title: 'Test Movie', year: 2024 },
    ids: { imdb: 'tt1234567', tmdb: 100, tvdb: null, douban: null },
    ratings: {
      imdb: { score: 8.5, votes: 1000 },
      rottenTomatoes: null,
      metacritic: null,
      letterboxd: null,
      tmdb: null,
      douban: null,
    },
    meta: { cached: false, stale: false, updatedAt: new Date().toISOString() },
  };

  beforeEach(() => {
    db = createMockD1Database();
    cacheStore.clear();
    CacheService.clearL1();
  });

  it('stores and retrieves L1 in-memory cache', async () => {
    await CacheService.setL1(1, mockResponse, 1000, cache);
    const cached = await CacheService.getL1(1, cache);

    expect(cached).toBeDefined();
    expect(cached?.meta.cached).toBe(true);
    expect(cached?.meta.stale).toBe(false);
    expect(cached?.media.title).toBe('Test Movie');
  });

  it('expires L1 cache when TTL passes', async () => {
    await CacheService.setL1(1, mockResponse, -10, cache); // already expired
    const cached = await CacheService.getL1(1, cache);

    expect(cached).toBeNull();
  });

  it('stores and retrieves D1 persistent cache', async () => {
    const mdblistData = {
      imdb: { score: 9.0, votes: 5000 },
      title: 'Breaking Bad',
      year: 2008,
    };

    await CacheService.setD1ProviderRating(db, 1, 'mdblist', mdblistData, 7 * 24 * 60 * 60 * 1000);

    const ratings = await CacheService.getD1ProviderRatings(db, 1);
    expect(ratings.mdblist).toBeDefined();
    expect(ratings.mdblist?.isFresh).toBe(true);
    expect(ratings.mdblist?.data?.imdb?.score).toBe(9.0);
  });

  it('invalidates both L1 and D1 cache', async () => {
    await CacheService.setL1(1, mockResponse, 10000);
    await CacheService.setD1ProviderRating(db, 1, 'mdblist', { title: 'Test' }, 10000);

    await CacheService.invalidate(db, 1);

    const l1 = await CacheService.getL1(1);
    const d1 = await CacheService.getD1ProviderRatings(db, 1);

    expect(l1).toBeNull();
    expect(d1.mdblist).toBeNull();
  });
});
