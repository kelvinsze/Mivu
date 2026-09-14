import { MediaIdentity, MDBListNormalizedResult, DoubanNormalizedResult } from '../types/env';

export interface ProviderResult<T> {
  success: boolean;
  data: T | null;
  provider: string;
  source: 'network' | 'cache' | 'negative_cache';
  statusCode?: number;
  error?: string;
  isNotFound?: boolean;
}

export interface RatingProvider<T> {
  name: string;
  fetchRatings(identity: MediaIdentity): Promise<ProviderResult<T>>;
}

export type MDBListProviderResult = ProviderResult<MDBListNormalizedResult>;
export type DoubanProviderResult = ProviderResult<DoubanNormalizedResult>;
