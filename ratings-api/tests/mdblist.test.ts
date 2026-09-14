import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { MDBListProvider } from '../src/providers/mdblist';
import { globalCircuitBreaker } from '../src/providers/circuit-breaker';

describe('MDBListProvider Unit Tests', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalCircuitBreaker.reset('mdblist');
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('calculates dynamic TTL according to media age', () => {
    const DAY_MS = 24 * 60 * 60 * 1000;
    const currentYear = new Date().getFullYear();

    expect(MDBListProvider.calculateTTL(currentYear)).toBe(7 * DAY_MS);
    expect(MDBListProvider.calculateTTL(currentYear - 1)).toBe(7 * DAY_MS);
    expect(MDBListProvider.calculateTTL(currentYear - 3)).toBe(14 * DAY_MS);
    expect(MDBListProvider.calculateTTL(currentYear - 15)).toBe(30 * DAY_MS);
    expect(MDBListProvider.calculateTTL(null)).toBe(7 * DAY_MS);
  });

  it('normalizes valid MDBList payload correctly', async () => {
    const mockPayload = {
      id: 1396,
      title: 'Breaking Bad',
      year: 2008,
      type: 'show',
      imdbid: 'tt0903747',
      tmdbid: 1396,
      tvdbid: 81189,
      ratings: [
        { source: 'imdb', value: 9.5, votes: 2300000 },
        { source: 'tomatoes', value: 96 },
        { source: 'tomatoesaudience', value: 97 },
        { source: 'metacritic', value: 87 },
        { source: 'letterboxd', value: 4.5 },
        { source: 'tmdb', value: 8.9, votes: 15000 },
      ],
    };

    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify(mockPayload), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      })
    );

    const provider = new MDBListProvider('test-key');
    const result = await provider.fetchRatings({
      mediaType: 'tv',
      imdbId: 'tt0903747',
    });

    expect(result.success).toBe(true);
    expect(result.data).toBeDefined();
    expect(result.data?.imdb).toEqual({ score: 9.5, votes: 2300000 });
    expect(result.data?.rottenTomatoes).toEqual({ critics: 96, audience: 97 });
    expect(result.data?.metacritic).toEqual({ score: 87 });
    expect(result.data?.letterboxd).toEqual({ score: 4.5 });
    expect(result.data?.tmdb).toEqual({ score: 8.9, votes: 15000 });
    expect(result.data?.title).toBe('Breaking Bad');
    expect(result.data?.year).toBe(2008);
  });

  it('handles 404 response gracefully', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ response: 'False', error: 'Movie not found!' }), {
        status: 404,
        headers: { 'Content-Type': 'application/json' },
      })
    );

    const provider = new MDBListProvider('test-key');
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      imdbId: 'tt9999999',
    });

    expect(result.success).toBe(false);
    expect(result.isNotFound).toBe(true);
    expect(result.statusCode).toBe(404);
  });

  it('falls back to the type-specific IMDb endpoint when the any endpoint rejects the lookup', async () => {
    const mockPayload = {
      title: 'The Matrix',
      ratings: [{ source: 'imdb', value: 8.7 }],
    };
    globalThis.fetch = vi.fn().mockImplementation((url: string) => {
      if (url.includes('/imdb/any/')) return Promise.resolve(new Response('', { status: 400 }));
      if (url.includes('/imdb/movie/')) return Promise.resolve(new Response(JSON.stringify(mockPayload), { status: 200 }));
      return Promise.reject(new Error(`Unexpected URL: ${url}`));
    });

    const provider = new MDBListProvider('test-key');
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      imdbId: 'tt0133093',
    });

    expect(result.success).toBe(true);
    expect(result.data?.imdb?.score).toBe(8.7);
    expect(globalThis.fetch).toHaveBeenCalledTimes(2);
  });

  it('handles 429 rate limit response', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ response: 'False', error: 'Rate limit reached' }), {
        status: 429,
        headers: { 'Content-Type': 'application/json' },
      })
    );

    const provider = new MDBListProvider('test-key');
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      imdbId: 'tt0903747',
    });

    expect(result.success).toBe(false);
    expect(result.statusCode).toBe(429);
  });

  it('handles upstream timeout', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new DOMException('The operation timed out.', 'TimeoutError'));

    const provider = new MDBListProvider('test-key');
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      imdbId: 'tt0903747',
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain('timeout');
  });

  it('handles malformed JSON response', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response('not json response', {
        status: 200,
        headers: { 'Content-Type': 'text/html' },
      })
    );

    const provider = new MDBListProvider('test-key');
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      imdbId: 'tt0903747',
    });

    expect(result.success).toBe(false);
  });
});
