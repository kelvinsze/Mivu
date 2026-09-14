import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { DoubanProvider } from '../src/providers/douban';
import { globalCircuitBreaker } from '../src/providers/circuit-breaker';
import { MediaIdentity } from '../src/types/env';

describe('DoubanProvider Unit Tests', () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalCircuitBreaker.reset('douban');
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it('scrapes rating and votes when Douban ID is already known', async () => {
    const mockHtml = `
      <!DOCTYPE html>
      <html>
        <head>
          <meta itemprop="name" content="肖申克的救赎 - 电影">
          <meta itemprop="ratingValue" content="9.7">
          <meta itemprop="reviewCount" content="3339884">
        </head>
        <body></body>
      </html>
    `;

    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response(mockHtml, {
        status: 200,
        headers: { 'Content-Type': 'text/html' },
      })
    );

    const provider = new DoubanProvider(true);
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      doubanId: '1292052',
    });

    expect(result.success).toBe(true);
    expect(result.data?.score).toBe(9.7);
    expect(result.data?.votes).toBe(3339884);
    expect(result.data?.subjectId).toBe('1292052');
    expect(result.data?.url).toBe('https://movie.douban.com/subject/1292052/');
  });

  it('resolves Douban ID via IMDb ID search when Douban ID is unknown', async () => {
    const mockSearchHtml = `
      <ul>
        <li><a href="/movie/subject/1292052/" data-imdb-id="tt0111161">肖申克的救赎</a></li>
      </ul>
    `;
    const mockSubjectHtml = `
      <meta itemprop="ratingValue" content="9.7">
      <meta itemprop="reviewCount" content="3000000">
    `;

    globalThis.fetch = vi.fn().mockImplementation((url: string) => {
      if (url.includes('/search/?query=')) {
        return Promise.resolve(new Response(mockSearchHtml, { status: 200 }));
      }
      return Promise.resolve(new Response(mockSubjectHtml, { status: 200 }));
    });

    const provider = new DoubanProvider(true);
    const identity: MediaIdentity = {
      mediaType: 'movie',
      imdbId: 'tt0111161',
    };

    const result = await provider.fetchRatings(identity);

    expect(result.success).toBe(true);
    expect(result.data?.subjectId).toBe('1292052');
    expect(result.data?.score).toBe(9.7);
    expect(identity.doubanId).toBe('1292052');
  });

  it('does not accept an arbitrary first IMDb search result', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(
      new Response('<a href="/movie/subject/1292052/">unrelated result</a>', { status: 200 })
    );
    const provider = new DoubanProvider(true);
    const result = await provider.fetchRatings({ mediaType: 'movie', imdbId: 'tt0111161' });
    expect(result.success).toBe(false);
    expect(result.isNotFound).toBe(true);
  });

  it('handles item with no rating gracefully', async () => {
    const mockHtml = `
      <!DOCTYPE html>
      <html>
        <head>
          <meta itemprop="name" content="尚未上映的电影 - 电影">
        </head>
        <body><span class="rating_num"></span></body>
      </html>
    `;

    globalThis.fetch = vi.fn().mockResolvedValue(new Response(mockHtml, { status: 200 }));

    const provider = new DoubanProvider(true);
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      doubanId: '9999999',
    });

    expect(result.success).toBe(true);
    expect(result.data?.score).toBeNull();
    expect(result.data?.votes).toBeNull();
  });

  it('handles upstream timeout', async () => {
    globalThis.fetch = vi.fn().mockRejectedValue(new DOMException('The operation timed out.', 'TimeoutError'));

    const provider = new DoubanProvider(true);
    const result = await provider.fetchRatings({
      mediaType: 'movie',
      doubanId: '1292052',
    });

    expect(result.success).toBe(false);
    expect(result.error).toContain('timeout');
  });

  it('trips circuit breaker after consecutive failures', async () => {
    globalThis.fetch = vi.fn().mockResolvedValue(new Response('Forbidden', { status: 403 }));

    const provider = new DoubanProvider(true);

    for (let i = 0; i < 5; i++) {
      await provider.fetchRatings({ mediaType: 'movie', doubanId: '1292052' });
    }

    expect(globalCircuitBreaker.isOpen('douban')).toBe(true);

    // Next call is rejected immediately by circuit breaker without network call
    const cbResult = await provider.fetchRatings({ mediaType: 'movie', doubanId: '1292052' });
    expect(cbResult.success).toBe(false);
    expect(cbResult.error).toContain('circuit breaker');
  });
});
