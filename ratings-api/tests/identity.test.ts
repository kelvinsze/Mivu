import { describe, expect, it } from 'vitest';
import { IdentityService } from '../src/services/identity';
import { createMockD1Database } from './mock-d1';

describe('Identity resolution concurrency', () => {
  it('collapses concurrent resolutions for one TMDb identity', async () => {
    const db = createMockD1Database();
    const results = await Promise.all(
      Array.from({ length: 4 }, () =>
        IdentityService.resolveIdentity(db, { tmdb: 1396, type: 'tv' })
      )
    );

    expect(new Set(results.map((identity) => identity.id)).size).toBe(1);
    expect((db as unknown as { identities: unknown[] }).identities).toHaveLength(1);
  });

  it('recovers when a concurrent insert wins a TMDb uniqueness race', async () => {
    const db = createMockD1Database();
    const [byBoth, byTmdb] = await Promise.all([
      IdentityService.resolveIdentity(db, { imdb: 'tt0133093', tmdb: 603, type: 'movie' }),
      IdentityService.resolveIdentity(db, { tmdb: 603, type: 'movie' }),
    ]);

    expect(byBoth.id).toBe(byTmdb.id);
    expect((db as unknown as { identities: unknown[] }).identities).toHaveLength(1);
  });
});
