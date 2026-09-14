import { NormalizedRatingsResponse } from '../types/env';
import { getAllCachedRatings, upsertCachedRating, deleteCachedRatings } from '../db/ratings-cache';
import { MDBListNormalizedResult, DoubanNormalizedResult } from '../types/env';

const CACHE_ORIGIN = 'https://ratings-api.internal';

function cacheRequest(key: string): Request {
  return new Request(`${CACHE_ORIGIN}/${encodeURIComponent(key)}`);
}

function defaultCache(): Cache | undefined {
  // Cache API is available in a deployed Worker. It is intentionally absent in
  // the unit-test runtime, where D1 remains the deterministic cache layer.
  return typeof caches !== 'undefined' ? caches.default : undefined;
}

export class CacheService {
  /**
   * Generates cache key for identity
   */
  static getCacheKey(identityId: number): string {
    return `ratings:v1:identity:${identityId}`;
  }

  /**
   * Retrieves L1 cache from the shared Cloudflare Cache API.
   */
  static async getL1(identityId: number, cache: Cache | undefined = defaultCache()): Promise<NormalizedRatingsResponse | null> {
    const key = this.getCacheKey(identityId);
    if (!cache) return null;
    const response = await cache.match(cacheRequest(key));
    if (!response) return null;
    try {
      const payload = (await response.json()) as
        | NormalizedRatingsResponse
        | { data: NormalizedRatingsResponse; expiresAt: number };
      const data = 'data' in payload ? payload.data : payload;
      if ('data' in payload && Date.now() >= payload.expiresAt) {
        await cache.delete(cacheRequest(key));
        return null;
      }
      return {
        ...data,
        meta: { ...data.meta, cached: true, stale: false },
      };
    } catch {
      return null;
    }
  }

  /**
   * Sets L1 cache
   */
  static async setL1(
    identityId: number,
    data: NormalizedRatingsResponse,
    ttlMs: number,
    cache: Cache | undefined = defaultCache()
  ): Promise<void> {
    const key = this.getCacheKey(identityId);
    if (!cache) return;
    await cache.put(
      cacheRequest(key),
      new Response(JSON.stringify({ data, expiresAt: Date.now() + Math.max(0, ttlMs) }), {
        headers: {
          'Content-Type': 'application/json',
          'Cache-Control': `public, max-age=${Math.max(0, Math.floor(ttlMs / 1000))}`,
        },
      })
    );
  }

  /**
   * Retrieves L2 persistent cached provider ratings from D1
   */
  static async getD1ProviderRatings(
    db: D1Database,
    identityId: number
  ): Promise<{
    mdblist: { data: MDBListNormalizedResult | null; isFresh: boolean; isStale: boolean; fetchedAt: string } | null;
    douban: { data: DoubanNormalizedResult | null; isFresh: boolean; isStale: boolean; fetchedAt: string } | null;
  }> {
    const cachedMap = await getAllCachedRatings(db, identityId);

    let mdblistResult = null;
    const mdbEntry = cachedMap.get('mdblist');
    if (mdbEntry) {
      try {
        const parsed = JSON.parse(mdbEntry.payload);
        mdblistResult = {
          data: parsed as MDBListNormalizedResult,
          isFresh: mdbEntry.isFresh,
          isStale: mdbEntry.isStale,
          fetchedAt: mdbEntry.fetchedAt,
        };
      } catch {
        // Invalid JSON payload
      }
    }

    let doubanResult = null;
    const doubanEntry = cachedMap.get('douban');
    if (doubanEntry) {
      try {
        const parsed = JSON.parse(doubanEntry.payload);
        doubanResult = {
          data: parsed as DoubanNormalizedResult,
          isFresh: doubanEntry.isFresh,
          isStale: doubanEntry.isStale,
          fetchedAt: doubanEntry.fetchedAt,
        };
      } catch {
        // Invalid JSON payload
      }
    }

    return {
      mdblist: mdblistResult,
      douban: doubanResult,
    };
  }

  /**
   * Saves provider rating to D1 cache
   */
  static async setD1ProviderRating(
    db: D1Database,
    identityId: number,
    provider: 'mdblist' | 'douban',
    data: unknown,
    ttlMs: number
  ): Promise<void> {
    const now = new Date();
    const expiresAt = new Date(now.getTime() + ttlMs).toISOString();
    const payload = JSON.stringify(data);

    await upsertCachedRating(db, identityId, provider, payload, expiresAt, now.toISOString());
  }

  /**
   * Invalidates cache for an identity (both L1 and D1)
   */
  static async invalidate(db: D1Database, identityId: number): Promise<void> {
    const cache = defaultCache();
    if (cache) await cache.delete(cacheRequest(this.getCacheKey(identityId)));
    await deleteCachedRatings(db, identityId);
  }

  /**
   * Retained as a test hook for callers that previously cleared local state.
   */
  static clearL1(): void {
    // Cache API is managed by Cloudflare and cannot be synchronously flushed.
    // Tests use isolated D1 instances, so no process-local state is required.
  }
}
