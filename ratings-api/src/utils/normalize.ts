import {
  MediaIdentity,
  NormalizedRatingsResponse,
  RatingsMap,
  MDBListNormalizedResult,
  DoubanNormalizedResult,
} from '../types/env';

/**
 * Normalizes a string for title comparison (strips punctuation, trims, lowercases)
 */
export function normalizeTitleString(str?: string | null): string {
  if (!str) return '';
  return str
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[\p{P}\p{S}]/gu, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Parses numeric score safely
 */
export function parseScore(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const num = typeof value === 'number' ? value : parseFloat(String(value));
  return Number.isFinite(num) ? num : null;
}

/**
 * Parses votes count safely
 */
export function parseVotes(value: unknown): number | null {
  if (value === null || value === undefined) return null;
  const num = typeof value === 'number' ? value : parseInt(String(value), 10);
  return Number.isInteger(num) && num >= 0 ? num : null;
}

export interface DoubanMatchCandidate {
  id: string;
  title: string;
  subTitle?: string;
  year?: number | string | null;
  type?: string;
  imdbId?: string | null;
}

export interface MatchScoreResult {
  score: number;
  accepted: boolean;
  reasons: string[];
}

/**
 * Scores a Douban candidate according to Section 15 of the specification:
 * - exact original title match: +0.45
 * - exact localized title match: +0.35
 * - year exact match: +0.20
 * - IMDb identifier match: +1.00
 * - media type match: +0.10
 * Clamped to 0.0 - 1.0.
 * Acceptance threshold >= 0.85.
 */
export function calculateDoubanMatchConfidence(
  target: {
    title?: string | null;
    originalTitle?: string | null;
    year?: number | null;
    mediaType?: string | null;
    imdbId?: string | null;
  },
  candidate: DoubanMatchCandidate
): MatchScoreResult {
  let score = 0.0;
  const reasons: string[] = [];

  // IMDb exact match
  if (target.imdbId && candidate.imdbId && target.imdbId.trim().toLowerCase() === candidate.imdbId.trim().toLowerCase()) {
    score += 1.0;
    reasons.push('imdb_match');
  }

  const normTargetTitle = normalizeTitleString(target.title);
  const normTargetOrigTitle = normalizeTitleString(target.originalTitle);

  const normCandidateTitle = normalizeTitleString(candidate.title);
  const normCandidateSubTitle = normalizeTitleString(candidate.subTitle);

  // Exact original title match (+0.45)
  if (
    normTargetOrigTitle &&
    (normTargetOrigTitle === normCandidateTitle ||
      normTargetOrigTitle === normCandidateSubTitle ||
      (normCandidateSubTitle && normTargetOrigTitle.includes(normCandidateSubTitle)) ||
      (normCandidateSubTitle && normCandidateSubTitle.includes(normTargetOrigTitle)))
  ) {
    score += 0.45;
    reasons.push('original_title_match');
  }

  // Exact localized title match (+0.35)
  if (
    normTargetTitle &&
    (normTargetTitle === normCandidateTitle ||
      normTargetTitle === normCandidateSubTitle ||
      normCandidateTitle.includes(normTargetTitle) ||
      normTargetTitle.includes(normCandidateTitle))
  ) {
    // Avoid double counting if already matched original title with same text
    if (!reasons.includes('original_title_match') || normTargetTitle !== normTargetOrigTitle) {
      score += 0.35;
      reasons.push('localized_title_match');
    }
  }

  // Year exact match (+0.20)
  if (target.year && candidate.year) {
    const candYear = typeof candidate.year === 'number' ? candidate.year : parseInt(String(candidate.year), 10);
    if (target.year === candYear) {
      score += 0.20;
      reasons.push('year_match');
    } else if (Math.abs(target.year - candYear) === 1) {
      // Release year discrepancy across regions (e.g. festival release vs general release)
      score += 0.10;
      reasons.push('year_close');
    }
  }

  // Media type match (+0.10)
  if (target.mediaType && candidate.type) {
    const normTargetType = target.mediaType.toLowerCase();
    const normCandType = candidate.type.toLowerCase();
    if (
      (normTargetType === 'movie' && (normCandType === 'movie' || normCandType === 'film')) ||
      (normTargetType === 'tv' && (normCandType === 'tv' || normCandType === 'show' || normCandType === 'teleplay'))
    ) {
      score += 0.10;
      reasons.push('type_match');
    }
  }

  const clampedScore = Math.min(1.0, Math.max(0.0, Math.round(score * 100) / 100));
  const accepted = clampedScore >= 0.85;

  return {
    score: clampedScore,
    accepted,
    reasons,
  };
}

/**
 * Builds the unified response object adhering to Section 4
 */
export function buildUnifiedResponse(
  identity: MediaIdentity,
  mdblistData: MDBListNormalizedResult | null,
  doubanData: DoubanNormalizedResult | null,
  cached: boolean,
  stale: boolean,
  updatedAt?: string
): NormalizedRatingsResponse {
  const ratings: RatingsMap = {
    imdb: mdblistData?.imdb
      ? {
          score: mdblistData.imdb.score,
          votes: mdblistData.imdb.votes ?? null,
        }
      : null,
    rottenTomatoes: mdblistData?.rottenTomatoes
      ? {
          critics: mdblistData.rottenTomatoes.critics ?? null,
          audience: mdblistData.rottenTomatoes.audience ?? null,
        }
      : null,
    metacritic: mdblistData?.metacritic
      ? {
          score: mdblistData.metacritic.score,
        }
      : null,
    letterboxd: mdblistData?.letterboxd
      ? {
          score: mdblistData.letterboxd.score,
        }
      : null,
    tmdb: mdblistData?.tmdb
      ? {
          score: mdblistData.tmdb.score,
          votes: mdblistData.tmdb.votes ?? null,
        }
      : null,
    douban: doubanData && doubanData.score !== null
      ? {
          score: doubanData.score,
          votes: doubanData.votes ?? null,
          url: doubanData.url,
        }
      : null,
  };

  return {
    media: {
      type: identity.mediaType,
      title: identity.title || mdblistData?.title || doubanData?.title || null,
      year: identity.year || mdblistData?.year || doubanData?.year || null,
    },
    ids: {
      imdb: identity.imdbId || mdblistData?.imdbId || null,
      tmdb: identity.tmdbId || mdblistData?.tmdbId || null,
      tvdb: identity.tvdbId || mdblistData?.tvdbId || null,
      douban: identity.doubanId || doubanData?.subjectId || null,
    },
    ratings,
    meta: {
      cached,
      stale,
      updatedAt: updatedAt || new Date().toISOString(),
    },
  };
}
