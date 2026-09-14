import { MediaIdentity, MediaType, MDBListNormalizedResult } from '../types/env';
import { RatingProvider, MDBListProviderResult } from './types';
import { globalCircuitBreaker } from './circuit-breaker';
import { logger } from '../utils/logger';
import { parseScore, parseVotes } from '../utils/normalize';

export interface MDBListRawRating {
  source: string;
  value?: number | string | null;
  score?: number | string | null;
  votes?: number | string | null;
  popular?: number | string | null;
}

export interface MDBListRawResponse {
  id?: number | string;
  title?: string;
  year?: number | string;
  release_year?: number | string;
  type?: string;
  mediatype?: string;
  imdbid?: string;
  tmdbid?: number | string;
  tvdbid?: number | string;
  traktid?: number | string;
  score?: number | string;
  score_average?: number | string;
  ratings?: MDBListRawRating[];
  response?: string | boolean;
  error?: string;
  status_code?: number;
  [key: string]: unknown;
}

export class MDBListProvider implements RatingProvider<MDBListNormalizedResult> {
  name = 'mdblist';
  private apiKey?: string;
  private baseUrl: string;
  private enabled: boolean;

  constructor(apiKey?: string, baseUrl: string = 'https://api.mdblist.com', enabled: boolean = true) {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.enabled = enabled;
  }

  /**
   * Calculates dynamic cache TTL in milliseconds based on media release year (Section 10)
   * - Default: 7 days
   * - Released > 2 years ago: 14 days
   * - Released > 10 years ago: 30 days
   */
  static calculateTTL(year?: number | null): number {
    const currentYear = new Date().getFullYear();
    const DAY_MS = 24 * 60 * 60 * 1000;

    if (!year) {
      return 7 * DAY_MS;
    }

    const age = currentYear - year;
    if (age >= 10) {
      return 30 * DAY_MS;
    }
    if (age >= 2) {
      return 14 * DAY_MS;
    }
    return 7 * DAY_MS;
  }

  async fetchRatings(identity: MediaIdentity): Promise<MDBListProviderResult> {
    if (!this.enabled || !this.apiKey) {
      return {
        success: false,
        data: null,
        provider: this.name,
        source: 'network',
        error: !this.enabled ? 'MDBList provider disabled' : 'MDBLIST_API_KEY is not configured',
      };
    }

    if (globalCircuitBreaker.isOpen(this.name)) {
      logger.warn('mdblist_circuit_breaker_open', { identity: identity.imdbId || String(identity.tmdbId) });
      return {
        success: false,
        data: null,
        provider: this.name,
        source: 'network',
        error: 'MDBList circuit breaker is open',
      };
    }

    // Determine request URL and parameters
    let url: string;
    const mediaType = identity.mediaType === 'tv' ? 'show' : 'movie';

    if (identity.imdbId) {
      // Direct IMDb query via MDBList API endpoint
      url = `${this.baseUrl}/imdb/any/${encodeURIComponent(identity.imdbId)}/?apikey=${encodeURIComponent(this.apiKey)}`;
    } else if (identity.tmdbId) {
      url = `${this.baseUrl}/tmdb/${mediaType}/${encodeURIComponent(identity.tmdbId)}/?apikey=${encodeURIComponent(this.apiKey)}`;
    } else if (identity.tvdbId) {
      url = `${this.baseUrl}/tvdb/show/${encodeURIComponent(identity.tvdbId)}/?apikey=${encodeURIComponent(this.apiKey)}`;
    } else {
      return {
        success: false,
        data: null,
        provider: this.name,
        source: 'network',
        error: 'No valid identifier available for MDBList',
      };
    }

    try {
      const response = await fetch(url, {
        headers: {
          'User-Agent': 'MivuRatingsAPI/1.0',
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(5000),
      });

      if (response.status === 404) {
        return {
          success: false,
          data: null,
          provider: this.name,
          source: 'network',
          statusCode: 404,
          isNotFound: true,
          error: 'Media not found on MDBList',
        };
      }

      if (response.status === 429) {
        globalCircuitBreaker.recordFailure(this.name);
        return {
          success: false,
          data: null,
          provider: this.name,
          source: 'network',
          statusCode: 429,
          error: 'MDBList API rate limit reached',
        };
      }

      if (!response.ok) {
        globalCircuitBreaker.recordFailure(this.name);
        return {
          success: false,
          data: null,
          provider: this.name,
          source: 'network',
          statusCode: response.status,
          error: `MDBList HTTP error: ${response.status}`,
        };
      }

      const raw = (await response.json()) as MDBListRawResponse;

      // Handle MDBList error payload
      if (raw.response === 'False' || raw.error) {
        if (raw.error?.toLowerCase().includes('not found')) {
          return {
            success: false,
            data: null,
            provider: this.name,
            source: 'network',
            statusCode: 404,
            isNotFound: true,
            error: raw.error,
          };
        }
        globalCircuitBreaker.recordFailure(this.name);
        return {
          success: false,
          data: null,
          provider: this.name,
          source: 'network',
          error: raw.error || 'Unknown MDBList error',
        };
      }

      const normalized = this.normalizeMDBListResponse(raw);
      globalCircuitBreaker.recordSuccess(this.name);

      return {
        success: true,
        data: normalized,
        provider: this.name,
        source: 'network',
        statusCode: 200,
      };
    } catch (err: unknown) {
      globalCircuitBreaker.recordFailure(this.name);
      const isTimeout = err instanceof Error && err.name === 'TimeoutError';
      return {
        success: false,
        data: null,
        provider: this.name,
        source: 'network',
        error: isTimeout ? 'MDBList upstream timeout after 5000ms' : String(err),
      };
    }
  }

  /**
   * Normalizes MDBList raw API response to our unified schema format
   */
  normalizeMDBListResponse(raw: MDBListRawResponse): MDBListNormalizedResult {
    let imdbRating: { score: number; votes?: number } | null = null;
    let rtCritics: number | null = null;
    let rtAudience: number | null = null;
    let metacriticScore: number | null = null;
    let letterboxdScore: number | null = null;
    let tmdbRating: { score: number; votes?: number } | null = null;

    // Parse ratings list if present
    const rawRatings = Array.isArray(raw.ratings) ? raw.ratings : [];
    for (const item of rawRatings) {
      if (!item || !item.source) continue;
      const source = item.source.toLowerCase();
      const val = parseScore(item.value ?? item.score);
      const votes = parseVotes(item.votes);

      if (val === null) continue;

      if (source === 'imdb' || source.includes('internet movie database')) {
        imdbRating = { score: val, votes: votes ?? undefined };
      } else if (source === 'tomatoes' || source === 'rotten tomatoes' || source === 'rtomatoes') {
        rtCritics = Math.round(val);
      } else if (
        source === 'tomatoesaudience' ||
        source === 'popcorn' ||
        source === 'rtaudience' ||
        source.includes('audience')
      ) {
        rtAudience = Math.round(val);
      } else if (source === 'metacritic') {
        metacriticScore = Math.round(val);
      } else if (source === 'letterboxd') {
        letterboxdScore = val;
      } else if (source === 'tmdb') {
        tmdbRating = { score: val, votes: votes ?? undefined };
      }
    }

    // Top-level fallbacks if ratings array didn't have them
    if (!imdbRating && raw.imdbrating) {
      const score = parseScore(raw.imdbrating);
      if (score !== null) {
        imdbRating = {
          score,
          votes: parseVotes(raw.imdbvotes) ?? undefined,
        };
      }
    }

    if (rtCritics === null && raw.rtomatoes) {
      rtCritics = parseScore(raw.rtomatoes);
    }
    if (rtAudience === null && raw.rtaudience) {
      rtAudience = parseScore(raw.rtaudience);
    }
    if (metacriticScore === null && raw.metacritic) {
      metacriticScore = parseScore(raw.metacritic);
    }
    if (letterboxdScore === null && raw.letterrating) {
      letterboxdScore = parseScore(raw.letterrating);
    }

    const yearVal = raw.year || raw.release_year;
    const year = typeof yearVal === 'number' ? yearVal : parseInt(String(yearVal), 10);

    const typeStr = (raw.mediatype || raw.type || '').toLowerCase();
    const mediaType: MediaType = typeStr === 'show' || typeStr === 'tv' ? 'tv' : 'movie';

    const tmdbIdNum = raw.tmdbid ? parseInt(String(raw.tmdbid), 10) : undefined;
    const tvdbIdNum = raw.tvdbid ? parseInt(String(raw.tvdbid), 10) : undefined;

    return {
      imdb: imdbRating,
      rottenTomatoes:
        rtCritics !== null || rtAudience !== null
          ? {
              critics: rtCritics,
              audience: rtAudience,
            }
          : null,
      metacritic: metacriticScore !== null ? { score: metacriticScore } : null,
      letterboxd: letterboxdScore !== null ? { score: letterboxdScore } : null,
      tmdb: tmdbRating,
      title: raw.title || null,
      year: Number.isInteger(year) ? year : null,
      mediaType,
      imdbId: raw.imdbid || null,
      tmdbId: tmdbIdNum && Number.isInteger(tmdbIdNum) ? tmdbIdNum : null,
      tvdbId: tvdbIdNum && Number.isInteger(tvdbIdNum) ? tvdbIdNum : null,
    };
  }
}
