import { MediaIdentity, DoubanNormalizedResult } from '../types/env';
import { RatingProvider, DoubanProviderResult } from './types';
import { globalCircuitBreaker } from './circuit-breaker';
import { logger } from '../utils/logger';
import { calculateDoubanMatchConfidence, DoubanMatchCandidate } from '../utils/normalize';

const USER_AGENT =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

// Keep scrape/search pressure bounded per Worker isolate. A failed request
// releases its slot in finally, so one blocked subject cannot starve others.
const MAX_DOUBAN_CONCURRENCY = 3;
let activeDoubanRequests = 0;
const doubanWaiters: Array<() => void> = [];

async function withDoubanSlot<T>(operation: () => Promise<T>): Promise<T> {
  if (activeDoubanRequests >= MAX_DOUBAN_CONCURRENCY) {
    await new Promise<void>((resolve) => doubanWaiters.push(resolve));
  }
  activeDoubanRequests += 1;
  try {
    return await operation();
  } finally {
    activeDoubanRequests -= 1;
    doubanWaiters.shift()?.();
  }
}

export interface DoubanSuggestItem {
  id: string;
  title: string;
  sub_title?: string;
  year?: string;
  type?: string;
  episode?: string;
  url?: string;
}

export class DoubanProvider implements RatingProvider<DoubanNormalizedResult> {
  name = 'douban';
  private enabled: boolean;
  private timeoutMs: number;

  constructor(enabled: boolean = true, timeoutMs: number = 5000) {
    this.enabled = enabled;
    this.timeoutMs = timeoutMs;
  }

  async fetchRatings(identity: MediaIdentity): Promise<DoubanProviderResult> {
    if (!this.enabled) {
      return {
        success: false,
        data: null,
        provider: this.name,
        source: 'network',
        error: 'Douban provider disabled',
      };
    }

    if (globalCircuitBreaker.isOpen(this.name)) {
      logger.warn('douban_circuit_breaker_open', { identity: identity.imdbId || identity.doubanId });
      return {
        success: false,
        data: null,
        provider: this.name,
        source: 'network',
        error: 'Douban circuit breaker is open',
      };
    }

    try {
      let subjectId = identity.doubanId;
      let matchConfidence = identity.doubanMatchConfidence ?? 1.0;
      let matchSource = identity.doubanMatchSource ?? 'manual';

      // Level 1: If Douban ID is not yet resolved, perform resolution
      if (!subjectId) {
        const resolved = await this.resolveDoubanSubjectId(identity);
        if (!resolved) {
          return {
            success: false,
            data: null,
            provider: this.name,
            source: 'negative_cache',
            isNotFound: true,
            error: 'No reliable Douban subject found',
          };
        }

        subjectId = resolved.subjectId;
        matchConfidence = resolved.confidence;
        matchSource = resolved.source;

        // Attach resolved data back to identity for caller to persist
        identity.doubanId = subjectId;
        identity.doubanMatchConfidence = matchConfidence;
        identity.doubanMatchSource = matchSource;
      }

      // Fetch ratings from subject page under the isolate-wide concurrency cap.
      const ratingData = await withDoubanSlot(() => this.scrapeDoubanSubject(subjectId));
      globalCircuitBreaker.recordSuccess(this.name);

      return {
        success: true,
        data: ratingData,
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
        error: isTimeout ? 'Douban upstream timeout after 5000ms' : String(err),
      };
    }
  }

  /**
   * Resolves Douban Subject ID using hierarchical matching:
   * Level 2: IMDb ID query on Douban search
   * Level 3: Title & Year query on subject_suggest / search with candidate confidence calculation
   */
  async resolveDoubanSubjectId(identity: MediaIdentity): Promise<{
    subjectId: string;
    confidence: number;
    source: 'auto' | 'external';
  } | null> {
    // 1. Try resolving via IMDb ID if available
    if (identity.imdbId) {
      const subjectId = await this.searchByImdbId(identity.imdbId!);
      if (subjectId) {
        return {
          subjectId,
          confidence: 0.95,
          source: 'auto',
        };
      }
    }

    // 2. Try searching by Title (original title first, then localized title)
    const titlesToTry: string[] = [];
    if (identity.originalTitle) titlesToTry.push(identity.originalTitle);
    if (identity.title && identity.title !== identity.originalTitle) titlesToTry.push(identity.title);

    for (const title of titlesToTry) {
      const candidates = await this.searchCandidates(title);
      let bestCandidate: DoubanMatchCandidate | null = null;
      let highestScore = 0;

      for (const cand of candidates) {
        const result = calculateDoubanMatchConfidence(
          {
            title: identity.title,
            originalTitle: identity.originalTitle,
            year: identity.year,
            mediaType: identity.mediaType,
            imdbId: identity.imdbId,
          },
          cand
        );

        if (result.score > highestScore) {
          highestScore = result.score;
          bestCandidate = cand;
        }
      }

      // Acceptance threshold >= 0.85 (Section 15)
      if (bestCandidate && highestScore >= 0.85) {
        return {
          subjectId: bestCandidate.id,
          confidence: highestScore,
          source: 'auto',
        };
      }
    }

    return null;
  }

  /**
   * Searches Douban mobile search with IMDb ID
   */
  async searchByImdbId(imdbId: string): Promise<string | null> {
    const url = `https://m.douban.com/search/?query=${encodeURIComponent(imdbId)}`;
    const response = await withDoubanSlot(() => fetch(url, {
      headers: {
        'User-Agent': USER_AGENT,
        Accept: 'text/html,application/xhtml+xml',
      },
      signal: AbortSignal.timeout(this.timeoutMs),
    }));

    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Douban IMDb search returned HTTP ${response.status}`);
    }

    const html = await response.text();
    // The mobile result markup does not expose the IMDb ID beside each subject.
    // IMDb itself is an exact lookup key, so accept its first movie result while
    // keeping title searches on the stricter title/year matching path below.
    const subjectPattern = /\/subject\/(\d+)\//g;
    let firstSubjectId: string | null = null;
    const escapedImdbId = imdbId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const exactId = new RegExp(`(?:data-imdb-id|imdb(?:\\s*id)?|/title/)[^a-z0-9]*${escapedImdbId}`, 'i');
    let match: RegExpExecArray | null;
    while ((match = subjectPattern.exec(html)) !== null) {
      firstSubjectId ||= match[1];
      const context = html.slice(Math.max(0, match.index - 600), match.index + 1200);
      if (exactId.test(context)) return match[1];
    }
    return firstSubjectId;
  }

  /**
   * Searches candidates via subject_suggest or fallback to mobile search
   */
  async searchCandidates(query: string): Promise<DoubanMatchCandidate[]> {
    const candidates: DoubanMatchCandidate[] = [];
    let networkError: unknown = null;

    try {
      // Try desktop subject_suggest JSON API
      const suggestUrl = `https://movie.douban.com/j/subject_suggest?q=${encodeURIComponent(query)}`;
      const response = await withDoubanSlot(() => fetch(suggestUrl, {
        headers: {
          'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
          Accept: 'application/json',
        },
        signal: AbortSignal.timeout(this.timeoutMs),
      }));

      if (response.ok) {
        const items = (await response.json()) as DoubanSuggestItem[];
        if (Array.isArray(items)) {
          for (const item of items) {
            if (item.id) {
              candidates.push({
                id: String(item.id),
                title: item.title,
                subTitle: item.sub_title,
                year: item.year,
                type: item.episode ? 'tv' : item.type || 'movie',
              });
            }
          }
        }
      } else if (response.status !== 404) {
        networkError = new Error(`Douban suggest returned HTTP ${response.status}`);
      }
    } catch (err) {
      networkError = err;
    }

    // If suggest returned nothing, try mobile search HTML
    if (candidates.length === 0) {
      try {
        const searchUrl = `https://m.douban.com/search/?query=${encodeURIComponent(query)}`;
        const response = await withDoubanSlot(() => fetch(searchUrl, {
          headers: {
            'User-Agent': USER_AGENT,
            Accept: 'text/html,application/xhtml+xml',
          },
          signal: AbortSignal.timeout(this.timeoutMs),
        }));

        if (response.ok) {
          networkError = null;
          const html = await response.text();
          // Regex match items: <a href="/movie/subject/(\d+)/"> ... <span class="subject-title">([^<]+)</span>
          const regex = /href="\/movie\/subject\/(\d+)\/"[\s\S]*?<span class="subject-title">([^<]+)<\/span>/g;
          let match: RegExpExecArray | null;
          while ((match = regex.exec(html)) !== null && candidates.length < 5) {
            candidates.push({
              id: match[1],
              title: match[2].trim(),
            });
          }
        } else if (response.status !== 404) {
          networkError = new Error(`Douban mobile search returned HTTP ${response.status}`);
        }
      } catch (err) {
        if (networkError) {
          throw networkError;
        }
        throw err;
      }
    }

    if (candidates.length === 0 && networkError) {
      throw networkError;
    }

    return candidates;
  }

  /**
   * Scrapes rating details from Douban mobile subject page
   */
  async scrapeDoubanSubject(subjectId: string): Promise<DoubanNormalizedResult> {
    const url = `https://m.douban.com/movie/subject/${encodeURIComponent(subjectId)}/`;
    const response = await fetch(url, {
      headers: {
        'User-Agent': USER_AGENT,
        Accept: 'text/html,application/xhtml+xml',
      },
      signal: AbortSignal.timeout(this.timeoutMs),
    });

    if (!response.ok) {
      throw new Error(`Douban subject page returned status ${response.status}`);
    }

    const html = await response.text();

    // 1. Extract ratingValue: <meta itemprop="ratingValue" content="9.2"> or "ratingValue": "9.2"
    let score: number | null = null;
    const ratingMatch =
      html.match(/itemprop="ratingValue"\s+content="([0-9.]+)"/) ||
      html.match(/content="([0-9.]+)"\s+itemprop="ratingValue"/) ||
      html.match(/class="rating_num"[^>]*>([0-9.]+)</);
    if (ratingMatch) {
      score = parseFloat(ratingMatch[1]);
    }

    // 2. Extract reviewCount (votes): <meta itemprop="reviewCount" content="390811">
    let votes: number | null = null;
    const votesMatch =
      html.match(/itemprop="reviewCount"\s+content="(\d+)"/) ||
      html.match(/content="(\d+)"\s+itemprop="reviewCount"/) ||
      html.match(/property="v:votes">(\d+)</);
    if (votesMatch) {
      votes = parseInt(votesMatch[1], 10);
    }

    // 3. Extract title & media type if present
    const nameMatch = html.match(/itemprop="name"\s+content="([^"]+)"/);
    let title: string | null = null;
    if (nameMatch) {
      title = nameMatch[1].replace(/\s*-\s*(电影|电视剧)$/, '').trim();
    }

    return {
      score: score !== null && !isNaN(score) ? score : null,
      votes: votes !== null && !isNaN(votes) ? votes : null,
      subjectId,
      url: `https://movie.douban.com/subject/${subjectId}/`,
      title,
    };
  }
}
