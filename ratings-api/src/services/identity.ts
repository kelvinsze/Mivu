import { MediaIdentity, IdentityLookupInput, MediaType } from '../types/env';
import {
  findIdentityByImdb,
  findIdentityByTmdb,
  findIdentityByTvdb,
  createIdentity,
  updateIdentity,
} from '../db/identity';

const identityResolutionInFlight = new Map<string, Promise<MediaIdentity>>();

export class IdentityService {
  /**
   * Resolves or creates a canonical MediaIdentity record in D1 (Section 22)
   * Preferred lookup priority: IMDb ID -> TMDb ID -> TVDb ID
   */
  static resolveIdentity(db: D1Database, input: IdentityLookupInput): Promise<MediaIdentity> {
    const key = `${input.imdb || ''}|${input.tmdb || ''}|${input.tvdb || ''}|${input.type || 'movie'}`;
    const existing = identityResolutionInFlight.get(key);
    if (existing) return existing;
    const pending = this.resolveIdentityUncoordinated(db, input).finally(() => {
      identityResolutionInFlight.delete(key);
    });
    identityResolutionInFlight.set(key, pending);
    return pending;
  }

  private static async resolveIdentityUncoordinated(db: D1Database, input: IdentityLookupInput): Promise<MediaIdentity> {
    let identity: MediaIdentity | null = null;
    const mediaType: MediaType = input.type || 'movie';

    // 1. Check by IMDb ID
    if (input.imdb) {
      identity = await findIdentityByImdb(db, input.imdb);
    }

    // 2. Check by TMDb ID if not found
    if (!identity && input.tmdb) {
      identity = await findIdentityByTmdb(db, input.tmdb, mediaType);
    }

    // 3. Check by TVDb ID if not found
    if (!identity && input.tvdb) {
      identity = await findIdentityByTvdb(db, input.tvdb, mediaType);
    }

    // If found, update any missing identifiers that were provided in input
    if (identity && identity.id) {
      const updates: Partial<MediaIdentity> = {};
      if (!identity.imdbId && input.imdb) updates.imdbId = input.imdb;
      if (!identity.tmdbId && input.tmdb) updates.tmdbId = input.tmdb;
      if (!identity.tvdbId && input.tvdb) updates.tvdbId = input.tvdb;

      if (Object.keys(updates).length > 0) {
        try {
          const updated = await updateIdentity(db, identity.id, updates);
          if (updated) identity = updated;
        } catch (error: unknown) {
          // Another resolver may have claimed a newly unique TMDb/TVDb ID.
          // Return that canonical row rather than leaking a D1 constraint 500.
          const conflict =
            (input.tmdb && (await findIdentityByTmdb(db, input.tmdb, mediaType))) ||
            (input.tvdb && (await findIdentityByTvdb(db, input.tvdb, mediaType))) ||
            null;
          if (conflict) return conflict;
          throw error;
        }
      }

      return identity;
    }

    // If still not found, create new record in D1. Two requests can resolve
    // the same identifier concurrently; unique-index conflicts are recovered
    // by reading the winner instead of surfacing a 500.
    try {
      return await createIdentity(db, {
        mediaType,
        imdbId: input.imdb || null,
        tmdbId: input.tmdb || null,
        tvdbId: input.tvdb || null,
      });
    } catch (error: unknown) {
      const existing =
        (input.imdb && (await findIdentityByImdb(db, input.imdb))) ||
        (input.tmdb && (await findIdentityByTmdb(db, input.tmdb, mediaType))) ||
        (input.tvdb && (await findIdentityByTvdb(db, input.tvdb, mediaType))) ||
        null;
      if (existing) return existing;
      throw error;
    }
  }

  /**
   * Enriches identity record with newly discovered upstream metadata
   */
  static async enrichIdentity(
    db: D1Database,
    identity: MediaIdentity,
    discovered: {
      imdbId?: string | null;
      tmdbId?: number | null;
      tvdbId?: number | null;
      doubanId?: string | null;
      title?: string | null;
      originalTitle?: string | null;
      year?: number | null;
      doubanMatchConfidence?: number | null;
      doubanMatchSource?: 'auto' | 'manual' | 'external' | null;
    }
  ): Promise<MediaIdentity> {
    if (!identity.id) return identity;

    const updates: Partial<MediaIdentity> = {};

    if (!identity.imdbId && discovered.imdbId) updates.imdbId = discovered.imdbId;
    if (!identity.tmdbId && discovered.tmdbId) updates.tmdbId = discovered.tmdbId;
    if (!identity.tvdbId && discovered.tvdbId) updates.tvdbId = discovered.tvdbId;
    if (discovered.doubanId && identity.doubanId !== discovered.doubanId) updates.doubanId = discovered.doubanId;
    if (!identity.title && discovered.title) updates.title = discovered.title;
    if (!identity.originalTitle && discovered.originalTitle) updates.originalTitle = discovered.originalTitle;
    if (!identity.year && discovered.year) updates.year = discovered.year;

    if (discovered.doubanMatchConfidence !== undefined && discovered.doubanMatchConfidence !== null) {
      updates.doubanMatchConfidence = discovered.doubanMatchConfidence;
    }
    if (discovered.doubanMatchSource) {
      updates.doubanMatchSource = discovered.doubanMatchSource;
    }

    if (Object.keys(updates).length > 0) {
      try {
        const updated = await updateIdentity(db, identity.id, updates);
        return updated || identity;
      } catch (error: unknown) {
        const conflict =
          (discovered.tmdbId && (await findIdentityByTmdb(db, discovered.tmdbId, identity.mediaType))) ||
          (discovered.tvdbId && (await findIdentityByTvdb(db, discovered.tvdbId, identity.mediaType))) ||
          null;
        if (conflict) return conflict;
        throw error;
      }
    }

    return identity;
  }

  /** Persists a resolver-discovered Douban mapping even when the provider
   * attached it to the in-flight identity object before D1 enrichment. */
  static async persistDoubanMapping(
    db: D1Database,
    identity: MediaIdentity,
    mapping: { doubanId: string; confidence: number; source: 'auto' | 'manual' | 'external' }
  ): Promise<MediaIdentity> {
    if (!identity.id) return identity;
    const updated = await updateIdentity(db, identity.id, {
      doubanId: mapping.doubanId,
      doubanMatchConfidence: mapping.confidence,
      doubanMatchSource: mapping.source,
    });
    return updated || identity;
  }

  /**
   * Sets manual Douban mapping (Section 32)
   */
  static async setManualDoubanMapping(
    db: D1Database,
    identifier: { imdb?: string; tmdb?: number; tvdb?: number; type?: MediaType },
    doubanId: string
  ): Promise<MediaIdentity> {
    const identity = await this.resolveIdentity(db, identifier);
    if (!identity.id) throw new Error('Failed to resolve identity record');

    const updated = await updateIdentity(db, identity.id, {
      doubanId,
      doubanMatchConfidence: 1.0,
      doubanMatchSource: 'manual',
    });

    if (!updated) throw new Error('Failed to update identity record');
    return updated;
  }
}
