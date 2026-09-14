import { MediaType } from '../types/env';

const IMDB_REGEX = /^tt\d{5,10}$/;

export function isValidImdbId(id?: string | null): boolean {
  if (!id) return false;
  return IMDB_REGEX.test(id.trim());
}

export function isValidPositiveInteger(id?: string | number | null): boolean {
  if (id === undefined || id === null) return false;
  if (typeof id === 'string' && !/^\d+$/.test(id.trim())) return false;
  const num = typeof id === 'number' ? id : Number(id);
  return Number.isSafeInteger(num) && num > 0;
}

export function parsePositiveInteger(id: unknown): number | undefined {
  if (typeof id === 'number') return isValidPositiveInteger(id) ? id : undefined;
  if (typeof id !== 'string' || !isValidPositiveInteger(id)) return undefined;
  const parsed = Number(id.trim());
  return isValidPositiveInteger(parsed) ? parsed : undefined;
}

export function isValidMediaType(type?: string | null): type is MediaType {
  return type === 'movie' || type === 'tv';
}

export interface ValidatedRatingsQuery {
  imdb?: string;
  tmdb?: number;
  tvdb?: number;
  type?: MediaType;
}

export interface ValidationResult {
  valid: boolean;
  error?: {
    code: string;
    message: string;
  };
  data?: ValidatedRatingsQuery;
}

export function validateRatingsQuery(params: {
  imdb?: string | null;
  tmdb?: string | null;
  tvdb?: string | null;
  type?: string | null;
}): ValidationResult {
  const rawImdb = params.imdb?.trim();
  const rawTmdb = params.tmdb?.trim();
  const rawTvdb = params.tvdb?.trim();
  const rawType = params.type?.trim().toLowerCase();

  if (!rawImdb && !rawTmdb && !rawTvdb) {
    return {
      valid: false,
      error: {
        code: 'MISSING_IDENTIFIER',
        message: 'At least one supported identifier (imdb, tmdb, or tvdb) must be provided.',
      },
    };
  }

  let imdb: string | undefined;
  let tmdb: number | undefined;
  let tvdb: number | undefined;
  let type: MediaType | undefined;

  if (rawImdb) {
    if (!isValidImdbId(rawImdb)) {
      return {
        valid: false,
        error: {
          code: 'INVALID_IMDB_ID',
          message: 'IMDb ID must match tt followed by digits.',
        },
      };
    }
    imdb = rawImdb;
  }

  if (rawTmdb) {
    if (!isValidPositiveInteger(rawTmdb)) {
      return {
        valid: false,
        error: {
          code: 'INVALID_TMDB_ID',
          message: 'TMDb ID must be a positive integer.',
        },
      };
    }
    tmdb = parseInt(rawTmdb, 10);
  }

  if (rawTvdb) {
    if (!isValidPositiveInteger(rawTvdb)) {
      return {
        valid: false,
        error: {
          code: 'INVALID_TVDB_ID',
          message: 'TVDb ID must be a positive integer.',
        },
      };
    }
    tvdb = parseInt(rawTvdb, 10);
  }

  if (rawType) {
    if (!isValidMediaType(rawType)) {
      return {
        valid: false,
        error: {
          code: 'INVALID_MEDIA_TYPE',
          message: 'Media type must be "movie" or "tv".',
        },
      };
    }
    type = rawType;
  }

  // If only TMDb or TVDb is provided without IMDb, media type is required for accurate lookup
  if (!imdb && (tmdb || tvdb) && !type) {
    return {
      valid: false,
      error: {
        code: 'MISSING_MEDIA_TYPE',
        message: 'Media type ("movie" or "tv") is required when querying by TMDb or TVDb ID without IMDb ID.',
      },
    };
  }

  return {
    valid: true,
    data: {
      imdb,
      tmdb,
      tvdb,
      type,
    },
  };
}
