export type MediaType = 'movie' | 'tv';

export interface Env {
  DB: D1Database;
  RATINGS_KV?: KVNamespace;
  MDBLIST_API_KEY?: string;
  APP_API_KEY?: string;
  ENVIRONMENT?: string;
  DOUBAN_ENABLED?: string;
  MDBLIST_ENABLED?: string;
}

export interface MediaIdentity {
  id?: number;
  mediaType: MediaType;
  imdbId?: string | null;
  tmdbId?: number | null;
  tvdbId?: number | null;
  doubanId?: string | null;
  title?: string | null;
  originalTitle?: string | null;
  year?: number | null;
  doubanMatchConfidence?: number | null;
  doubanMatchSource?: 'auto' | 'manual' | 'external' | null;
  createdAt?: string;
  updatedAt?: string;
}

export interface IdentityLookupInput {
  imdb?: string;
  tmdb?: number;
  tvdb?: number;
  type?: MediaType;
}

export interface RatingScoreVotes {
  score: number;
  votes?: number | null;
}

export interface RottenTomatoesRating {
  critics?: number | null;
  audience?: number | null;
}

export interface MetacriticRating {
  score: number;
}

export interface LetterboxdRating {
  score: number;
}

export interface DoubanRating {
  score: number | null;
  votes: number | null;
  url: string;
}

export interface RatingsMap {
  imdb: RatingScoreVotes | null;
  rottenTomatoes: RottenTomatoesRating | null;
  metacritic: MetacriticRating | null;
  letterboxd: LetterboxdRating | null;
  tmdb: RatingScoreVotes | null;
  douban: DoubanRating | null;
}

export interface NormalizedRatingsResponse {
  media: {
    type: MediaType;
    title: string | null;
    year: number | null;
  };
  ids: {
    imdb: string | null;
    tmdb: number | null;
    tvdb: number | null;
    douban: string | null;
  };
  ratings: RatingsMap;
  meta: {
    cached: boolean;
    stale: boolean;
    updatedAt: string;
  };
}

export interface MDBListNormalizedResult {
  imdb?: RatingScoreVotes | null;
  rottenTomatoes?: RottenTomatoesRating | null;
  metacritic?: MetacriticRating | null;
  letterboxd?: LetterboxdRating | null;
  tmdb?: RatingScoreVotes | null;
  title?: string | null;
  year?: number | null;
  mediaType?: MediaType | null;
  imdbId?: string | null;
  tmdbId?: number | null;
  tvdbId?: number | null;
}

export interface DoubanNormalizedResult {
  score: number | null;
  votes: number | null;
  subjectId: string;
  url: string;
  title?: string | null;
  originalTitle?: string | null;
  year?: number | null;
}
