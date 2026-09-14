import { describe, it, expect } from 'vitest';
import { calculateDoubanMatchConfidence } from '../src/utils/normalize';

describe('Douban Candidate Matching Unit Tests', () => {
  it('accepts exact IMDb match with maximum confidence (1.0)', () => {
    const target = {
      title: 'The Shawshank Redemption',
      imdbId: 'tt0111161',
    };
    const candidate = {
      id: '1292052',
      title: '肖申克的救赎',
      imdbId: 'tt0111161',
    };

    const result = calculateDoubanMatchConfidence(target, candidate);
    expect(result.score).toBe(1.0);
    expect(result.accepted).toBe(true);
    expect(result.reasons).toContain('imdb_match');
  });

  it('accepts exact original title + exact year + media type (>= 0.85)', () => {
    const target = {
      title: '绝命毒师',
      originalTitle: 'Breaking Bad',
      year: 2008,
      mediaType: 'tv',
    };
    const candidate = {
      id: '2373195',
      title: '绝命毒师 第一季',
      subTitle: 'Breaking Bad',
      year: 2008,
      type: 'tv',
    };

    const result = calculateDoubanMatchConfidence(target, candidate);
    // original title (+0.45) + localized title (+0.35) + year (+0.20) + type (+0.10) = 1.10 -> clamped 1.0
    expect(result.score).toBeGreaterThanOrEqual(0.85);
    expect(result.accepted).toBe(true);
  });

  it('rejects candidate when year differs significantly', () => {
    const target = {
      title: 'Dune',
      originalTitle: 'Dune',
      year: 2021,
      mediaType: 'movie',
    };
    const candidate1984 = {
      id: '1297597',
      title: '沙丘',
      subTitle: 'Dune',
      year: 1984,
      type: 'movie',
    };

    const result = calculateDoubanMatchConfidence(target, candidate1984);
    // originalTitle (+0.45) + type (+0.10) = 0.55 < 0.85
    expect(result.score).toBeLessThan(0.85);
    expect(result.accepted).toBe(false);
  });

  it('rejects candidate with low confidence and unrelated title', () => {
    const target = {
      title: 'Interstellar',
      originalTitle: 'Interstellar',
      year: 2014,
      mediaType: 'movie',
    };
    const candidate = {
      id: '9999999',
      title: '某个不相关的电影',
      subTitle: 'Unrelated',
      year: 2020,
      type: 'movie',
    };

    const result = calculateDoubanMatchConfidence(target, candidate);
    expect(result.score).toBeLessThan(0.70);
    expect(result.accepted).toBe(false);
  });

  it('rewards close year (release delay across regions)', () => {
    const target = {
      title: 'Parasite',
      originalTitle: 'Gisaengchung',
      year: 2019,
      mediaType: 'movie',
    };
    const candidate = {
      id: '27010768',
      title: '寄生虫',
      subTitle: 'Gisaengchung',
      year: 2020, // 1 year difference
      type: 'movie',
    };

    const result = calculateDoubanMatchConfidence(target, candidate);
    expect(result.reasons).toContain('year_close');
    expect(result.score).toBeGreaterThan(0.5);
  });
});
