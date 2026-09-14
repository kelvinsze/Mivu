import {
  Env,
  IdentityLookupInput,
  NormalizedRatingsResponse,
  MDBListNormalizedResult,
  DoubanNormalizedResult,
  MediaIdentity,
} from '../types/env';
import { IdentityService } from './identity';
import { CacheService } from './cache';
import { RequestDeduplicator } from './dedupe';
import { MDBListProvider } from '../providers/mdblist';
import { DoubanProvider } from '../providers/douban';
import { buildUnifiedResponse } from '../utils/normalize';
import { logger } from '../utils/logger';

const deduplicator = new RequestDeduplicator<{ response: NormalizedRatingsResponse; status: number }>();

function hasRatingData(
  mdblist: MDBListNormalizedResult | null | undefined,
  douban: DoubanNormalizedResult | null | undefined
): boolean {
  return !!(
    mdblist?.imdb ||
    mdblist?.rottenTomatoes ||
    mdblist?.metacritic ||
    mdblist?.letterboxd ||
    mdblist?.tmdb ||
    (douban && douban.score !== null)
  );
}

export class RatingsService {
  /**
   * Fetches ratings for a media identity, coordinating L1/L2 caches,
   * parallel upstream provider requests, failure isolation, and SWR.
   */
  static async getRatings(
    env: Env,
    input: IdentityLookupInput,
    forceRefresh: boolean = false,
    ctx?: { waitUntil?: (promise: Promise<unknown>) => void }
  ): Promise<{ response: NormalizedRatingsResponse; status: number }> {
    const startTime = Date.now();

    // Deduplicate before touching D1. Otherwise concurrent first requests all
    // perform the lookup/create sequence before the in-flight map is reached.
    const inputKey = input.imdb
      ? `imdb_${input.imdb}`
      : input.tmdb
        ? `tmdb_${input.tmdb}_${input.type || 'movie'}`
        : `tvdb_${input.tvdb}_${input.type || 'movie'}`;
    const dedupeKey = `${inputKey}_${forceRefresh}`;

    return deduplicator.execute(dedupeKey, async () => {
      // 1. Resolve canonical identity from D1
      let identity = await IdentityService.resolveIdentity(env.DB, input);
      const identityKey = identity.imdbId || `tmdb_${identity.tmdbId}_${identity.mediaType}`;
      // 2. Check L1 Cache if not forcing refresh
      if (!forceRefresh && identity.id) {
        const l1Cached = await CacheService.getL1(identity.id);
        if (l1Cached) {
          logger.info('ratings_request', {
            identity: identityKey,
            cache: 'hit',
            durationMs: Date.now() - startTime,
            status: 200,
          });
          return { response: l1Cached, status: 200 };
        }
      }

      // 3. Check L2 (D1) Persistent Cache
      let mdblistCached: {
        data: MDBListNormalizedResult | null;
        isFresh: boolean;
        isStale: boolean;
        fetchedAt: string;
      } | null = null;
      let doubanCached: {
        data: DoubanNormalizedResult | null;
        isFresh: boolean;
        isStale: boolean;
        fetchedAt: string;
      } | null = null;

      if (identity.id) {
        const d1Ratings = await CacheService.getD1ProviderRatings(env.DB, identity.id);
        mdblistCached = d1Ratings.mdblist;
        doubanCached = d1Ratings.douban;

        if (!forceRefresh) {
          // If both are fresh in D1, populate L1 and return immediately
          if (mdblistCached?.isFresh && doubanCached?.isFresh && hasRatingData(mdblistCached.data, doubanCached.data)) {
            const unified = buildUnifiedResponse(
              identity,
              mdblistCached.data,
              doubanCached.data,
              true,
              false,
              mdblistCached.fetchedAt
            );

            await CacheService.setL1(identity.id, unified, 60 * 1000); // 1 minute in L1

            logger.info('ratings_request', {
              identity: identityKey,
              cache: 'hit',
              providers: { mdblist: 'd1_cached', douban: 'd1_cached' },
              durationMs: Date.now() - startTime,
              status: 200,
            });

            return { response: unified, status: 200 };
          }

          // If we have cached data for at least one provider and it is stale (Section 11 SWR),
          // we can return the stale result immediately and trigger background refresh if ctx is available
          const hasAnyCached = mdblistCached?.data || doubanCached?.data;
          // SWR is only allowed during the 30-day stale window. Once the
          // provider entry is older than that, this request must revalidate
          // synchronously instead of serving an unboundedly old value.
          const isStale = !!(mdblistCached?.isStale || doubanCached?.isStale);

          if (hasAnyCached && isStale && ctx && typeof ctx.waitUntil === 'function') {
            const unifiedStale = buildUnifiedResponse(
              identity,
              mdblistCached?.data ?? null,
              doubanCached?.data ?? null,
              true,
              true,
              mdblistCached?.fetchedAt || doubanCached?.fetchedAt
            );

            // Asynchronous revalidation in background
            ctx.waitUntil(
              this.refreshProviders(env, identity, mdblistCached, doubanCached, forceRefresh).catch((err) => {
                logger.warn('background_revalidation_failed', { error: String(err) });
              })
            );

            logger.info('ratings_request', {
              identity: identityKey,
              cache: 'stale',
              durationMs: Date.now() - startTime,
              status: 200,
            });

            return { response: unifiedStale, status: 200 };
          }
        }
      }

      // 4. Upstream Provider Fetching
      const result = await this.refreshProviders(env, identity, mdblistCached, doubanCached, forceRefresh);
      logger.info('ratings_request', {
        identity: identityKey,
        cache: 'miss',
        durationMs: Date.now() - startTime,
        status: result.status,
      });

      return result;
    });
  }

  /**
   * Refreshes upstream providers in parallel using Promise.allSettled (Section 35)
   */
  private static async refreshProviders(
    env: Env,
    identity: MediaIdentity,
    mdblistCached: { data: MDBListNormalizedResult | null; isFresh: boolean; isStale: boolean; fetchedAt: string } | null,
    doubanCached: { data: DoubanNormalizedResult | null; isFresh: boolean; isStale: boolean; fetchedAt: string } | null,
    forceRefresh: boolean = false
  ): Promise<{ response: NormalizedRatingsResponse; status: number }> {
    const mdblistEnabled = env.MDBLIST_ENABLED !== 'false';
    const doubanEnabled = env.DOUBAN_ENABLED !== 'false';

    const mdblistProvider = new MDBListProvider(env.MDBLIST_API_KEY, undefined, mdblistEnabled);
    const doubanProvider = new DoubanProvider(doubanEnabled);
    const hadDoubanMapping = !!identity.doubanId;

    // Determine which providers need fetching
    const needsMdblist = forceRefresh || !mdblistCached || !mdblistCached.isFresh;
    const needsDouban = forceRefresh || !doubanCached || !doubanCached.isFresh;

    const promises: [
      Promise<{ success: boolean; data: MDBListNormalizedResult | null; isNotFound?: boolean; error?: string }>,
      Promise<{ success: boolean; data: DoubanNormalizedResult | null; isNotFound?: boolean; error?: string }>,
    ] = [
      needsMdblist
        ? mdblistProvider.fetchRatings(identity)
        : Promise.resolve({ success: true, data: mdblistCached?.data ?? null }),
      needsDouban
        ? doubanProvider.fetchRatings(identity)
        : Promise.resolve({ success: true, data: doubanCached?.data ?? null }),
    ];

    const [mdblistSettled, doubanSettled] = await Promise.allSettled(promises);

    // Douban resolution mutates the in-flight identity. Capture it before the
    // MDBList enrichment below can replace that object with a D1 snapshot.
    const resolvedDoubanMapping =
      !hadDoubanMapping && identity.doubanId
        ? {
            doubanId: identity.doubanId,
            confidence: identity.doubanMatchConfidence ?? 0,
            source: identity.doubanMatchSource ?? 'auto',
          }
        : null;

    let mdblistData: MDBListNormalizedResult | null = null;
    let mdblistFailed = false;
    let mdblistNotFound = false;

    if (mdblistSettled.status === 'fulfilled') {
      const res = mdblistSettled.value;
      if (res.success && res.data) {
        mdblistData = res.data;
        if (identity.id) {
          const ttl = MDBListProvider.calculateTTL(res.data.year || identity.year);
          await CacheService.setD1ProviderRating(env.DB, identity.id, 'mdblist', res.data, ttl);

          // Enrich identity in D1 with newly discovered metadata
          identity = await IdentityService.enrichIdentity(env.DB, identity, {
            imdbId: res.data.imdbId,
            tmdbId: res.data.tmdbId,
            tvdbId: res.data.tvdbId,
            title: res.data.title,
            year: res.data.year,
          });
        }
      } else if (res.isNotFound || (res.success && !!mdblistCached?.isFresh && !res.data)) {
        mdblistNotFound = true;
        // Negative cache MDBList 404 for 6 hours (Section 33)
        if (identity.id) {
          await CacheService.setD1ProviderRating(env.DB, identity.id, 'mdblist', null, 6 * 60 * 60 * 1000);
        }
      } else {
        mdblistFailed = true;
        // Fallback to stale D1 data if available
        if (mdblistCached?.data) {
          mdblistData = mdblistCached.data;
        }
      }
    } else {
      mdblistFailed = true;
      if (mdblistCached?.data) {
        mdblistData = mdblistCached.data;
      }
    }

    if (resolvedDoubanMapping) {
      identity = await IdentityService.persistDoubanMapping(env.DB, identity, resolvedDoubanMapping);
    }

    let doubanData: DoubanNormalizedResult | null = null;
    let doubanFailed = false;
    let doubanNotFound = false;

    if (doubanSettled.status === 'fulfilled') {
      const res = doubanSettled.value;
      if (res.success && res.data) {
        doubanData = res.data;
        if (identity.id) {
          const age = (identity.year ? new Date().getFullYear() - identity.year : 0);
          const doubanTTL = (age >= 10 ? 30 : age >= 2 ? 14 : 7) * 24 * 60 * 60 * 1000;
          await CacheService.setD1ProviderRating(env.DB, identity.id, 'douban', res.data, doubanTTL);

          // The resolver mapping is persisted above before this branch. Keep
          // this response identity synchronized with the D1 record.
        }
      } else if (res.isNotFound || (res.success && !!doubanCached?.isFresh && !res.data)) {
        doubanNotFound = true;
        // Negative cache Douban no-match for 24 hours (Section 33)
        if (identity.id) {
          await CacheService.setD1ProviderRating(env.DB, identity.id, 'douban', null, 24 * 60 * 60 * 1000);
        }
      } else {
        doubanFailed = true;
        if (doubanCached?.data) {
          doubanData = doubanCached.data;
        }
      }
    } else {
      doubanFailed = true;
      if (doubanCached?.data) {
        doubanData = doubanCached.data;
      }
    }

    const hasAnyData = hasRatingData(mdblistData, doubanData);

    // Section 5 Status Codes:
    // 200: At least one valid rating source returned data (partial results acceptable)
    if (hasAnyData) {
      const isStale = (mdblistFailed && !!mdblistData) || (doubanFailed && !!doubanData);
      const unified = buildUnifiedResponse(identity, mdblistData, doubanData, false, isStale);

      if (identity.id) {
        await CacheService.setL1(identity.id, unified, 60 * 1000);
      }

      return { response: unified, status: 200 };
    }

    // 502: All required/enabled upstream providers failed and no cached result exists
    const allProvidersFailed =
      (mdblistFailed || !mdblistEnabled) &&
      (doubanFailed || !doubanEnabled) &&
      (mdblistFailed || doubanFailed);

    if (allProvidersFailed) {
      const unified = buildUnifiedResponse(identity, null, null, false, false);
      return { response: unified, status: 502 };
    }

    // 404: Media cannot be resolved by any provider
    const unified = buildUnifiedResponse(identity, null, null, false, false);
    return { response: unified, status: 404 };
  }
}
