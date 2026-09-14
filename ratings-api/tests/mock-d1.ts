interface MockIdentityRow {
  id: number;
  media_type: string;
  imdb_id: string | null;
  tmdb_id: number | null;
  tvdb_id: number | null;
  douban_id: string | null;
  title: string | null;
  original_title: string | null;
  year: number | null;
  douban_match_confidence: number | null;
  douban_match_source: string | null;
  created_at: string;
  updated_at: string;
}

interface MockRatingsCacheRow {
  id: number;
  identity_id: number;
  provider: string;
  payload: string;
  fetched_at: string;
  expires_at: string;
}

export class MockD1Database {
  identities: MockIdentityRow[] = [];
  ratingsCache: MockRatingsCacheRow[] = [];
  private nextIdentityId = 1;
  private nextCacheId = 1;

  reset() {
    this.identities = [];
    this.ratingsCache = [];
    this.nextIdentityId = 1;
    this.nextCacheId = 1;
  }

  prepare(sql: string) {
    const db = this;
    let boundValues: unknown[] = [];

    const statement = {
      bind(...values: unknown[]) {
        boundValues = values;
        return statement;
      },

      async first<T = unknown>(): Promise<T | null> {
        const trimmed = sql.trim().toUpperCase();

        if (trimmed.startsWith('SELECT * FROM MEDIA_IDENTITY')) {
          if (trimmed.includes('WHERE IMDB_ID = ?')) {
            const imdb = boundValues[0] as string;
            const found = db.identities.find((i) => i.imdb_id === imdb);
            return (found as unknown as T) || null;
          }
          if (trimmed.includes('WHERE TMDB_ID = ? AND MEDIA_TYPE = ?')) {
            const tmdb = boundValues[0] as number;
            const type = boundValues[1] as string;
            const found = db.identities.find((i) => i.tmdb_id === tmdb && i.media_type === type);
            return (found as unknown as T) || null;
          }
          if (trimmed.includes('WHERE TVDB_ID = ? AND MEDIA_TYPE = ?')) {
            const tvdb = boundValues[0] as number;
            const type = boundValues[1] as string;
            const found = db.identities.find((i) => i.tvdb_id === tvdb && i.media_type === type);
            return (found as unknown as T) || null;
          }
          if (trimmed.includes('WHERE DOUBAN_ID = ?')) {
            const douban = boundValues[0] as string;
            const found = db.identities.find((i) => i.douban_id === douban);
            return (found as unknown as T) || null;
          }
          if (trimmed.includes('WHERE ID = ?')) {
            const id = boundValues[0] as number;
            const found = db.identities.find((i) => i.id === id);
            return (found as unknown as T) || null;
          }
        }

        if (trimmed.startsWith('SELECT * FROM RATINGS_CACHE')) {
          if (trimmed.includes('WHERE IDENTITY_ID = ? AND PROVIDER = ?')) {
            const identityId = boundValues[0] as number;
            const provider = boundValues[1] as string;
            const found = db.ratingsCache.find(
              (r) => r.identity_id === identityId && r.provider === provider
            );
            return (found as unknown as T) || null;
          }
        }

        return null;
      },

      async all<T = unknown>(): Promise<{ results: T[] }> {
        const trimmed = sql.trim().toUpperCase();

        if (trimmed.startsWith('SELECT * FROM RATINGS_CACHE WHERE IDENTITY_ID = ?')) {
          const identityId = boundValues[0] as number;
          const found = db.ratingsCache.filter((r) => r.identity_id === identityId);
          return { results: found as unknown as T[] };
        }

        return { results: [] };
      },

      async run(): Promise<{ meta: { last_row_id: number; changes: number } }> {
        const trimmed = sql.trim().toUpperCase();

        if (trimmed.startsWith('INSERT INTO MEDIA_IDENTITY')) {
          const [
            media_type,
            imdb_id,
            tmdb_id,
            tvdb_id,
            douban_id,
            title,
            original_title,
            year,
            douban_match_confidence,
            douban_match_source,
            created_at,
            updated_at,
          ] = boundValues as [
            string,
            string | null,
            number | null,
            number | null,
            string | null,
            string | null,
            string | null,
            number | null,
            number | null,
            string | null,
            string,
            string,
          ];

          if (
            db.identities.some(
              (row) =>
                (imdb_id !== null && row.imdb_id === imdb_id) ||
                (tmdb_id !== null && row.tmdb_id === tmdb_id && row.media_type === media_type) ||
                (tvdb_id !== null && row.tvdb_id === tvdb_id && row.media_type === media_type)
            )
          ) {
            throw new Error('UNIQUE constraint failed: media_identity identifier');
          }

          const id = db.nextIdentityId++;
          db.identities.push({
            id,
            media_type,
            imdb_id,
            tmdb_id,
            tvdb_id,
            douban_id,
            title,
            original_title,
            year,
            douban_match_confidence,
            douban_match_source,
            created_at,
            updated_at,
          });

          return { meta: { last_row_id: id, changes: 1 } };
        }

        if (trimmed.startsWith('UPDATE MEDIA_IDENTITY')) {
          const id = boundValues[boundValues.length - 1] as number;
          const identity = db.identities.find((i) => i.id === id);

          if (identity) {
            // Check fields updated
            if (trimmed.includes('IMDB_ID = ?')) {
              const idx = getBoundIndex(sql, 'imdb_id = ?');
              if (idx !== -1) identity.imdb_id = boundValues[idx] as string | null;
            }
            if (trimmed.includes('TMDB_ID = ?')) {
              const idx = getBoundIndex(sql, 'tmdb_id = ?');
              if (idx !== -1) identity.tmdb_id = boundValues[idx] as number | null;
            }
            if (trimmed.includes('TVDB_ID = ?')) {
              const idx = getBoundIndex(sql, 'tvdb_id = ?');
              if (idx !== -1) identity.tvdb_id = boundValues[idx] as number | null;
            }
            if (trimmed.includes('DOUBAN_ID = ?')) {
              const idx = getBoundIndex(sql, 'douban_id = ?');
              if (idx !== -1) identity.douban_id = boundValues[idx] as string | null;
            }
            if (trimmed.includes('TITLE = ?')) {
              const idx = getBoundIndex(sql, 'title = ?');
              if (idx !== -1) identity.title = boundValues[idx] as string | null;
            }
            if (trimmed.includes('ORIGINAL_TITLE = ?')) {
              const idx = getBoundIndex(sql, 'original_title = ?');
              if (idx !== -1) identity.original_title = boundValues[idx] as string | null;
            }
            if (trimmed.includes('YEAR = ?')) {
              const idx = getBoundIndex(sql, 'year = ?');
              if (idx !== -1) identity.year = boundValues[idx] as number | null;
            }
            if (trimmed.includes('DOUBAN_MATCH_CONFIDENCE = ?')) {
              const idx = getBoundIndex(sql, 'douban_match_confidence = ?');
              if (idx !== -1) identity.douban_match_confidence = boundValues[idx] as number | null;
            }
            if (trimmed.includes('DOUBAN_MATCH_SOURCE = ?')) {
              const idx = getBoundIndex(sql, 'douban_match_source = ?');
              if (idx !== -1) identity.douban_match_source = boundValues[idx] as string | null;
            }
            identity.updated_at = new Date().toISOString();
          }

          return { meta: { last_row_id: id, changes: identity ? 1 : 0 } };
        }

        if (trimmed.startsWith('INSERT INTO RATINGS_CACHE')) {
          const [identity_id, provider, payload, fetched_at, expires_at] = boundValues as [
            number,
            string,
            string,
            string,
            string,
          ];

          const existingIndex = db.ratingsCache.findIndex(
            (r) => r.identity_id === identity_id && r.provider === provider
          );

          if (existingIndex !== -1) {
            db.ratingsCache[existingIndex] = {
              ...db.ratingsCache[existingIndex],
              payload,
              fetched_at,
              expires_at,
            };
            return { meta: { last_row_id: db.ratingsCache[existingIndex].id, changes: 1 } };
          } else {
            const id = db.nextCacheId++;
            db.ratingsCache.push({
              id,
              identity_id,
              provider,
              payload,
              fetched_at,
              expires_at,
            });
            return { meta: { last_row_id: id, changes: 1 } };
          }
        }

        if (trimmed.startsWith('DELETE FROM RATINGS_CACHE')) {
          const identityId = boundValues[0] as number;
          if (trimmed.includes('AND PROVIDER = ?')) {
            const provider = boundValues[1] as string;
            const prevLen = db.ratingsCache.length;
            db.ratingsCache = db.ratingsCache.filter(
              (r) => !(r.identity_id === identityId && r.provider === provider)
            );
            return { meta: { last_row_id: 0, changes: prevLen - db.ratingsCache.length } };
          } else {
            const prevLen = db.ratingsCache.length;
            db.ratingsCache = db.ratingsCache.filter((r) => r.identity_id !== identityId);
            return { meta: { last_row_id: 0, changes: prevLen - db.ratingsCache.length } };
          }
        }

        return { meta: { last_row_id: 0, changes: 0 } };
      },
    };

    return statement;
  }
}

function getBoundIndex(sql: string, fragment: string): number {
  const parts = sql.toLowerCase().split(',');
  let currentIdx = 0;
  for (const part of parts) {
    if (part.includes(fragment.toLowerCase())) {
      return currentIdx;
    }
    if (part.includes('?')) {
      currentIdx++;
    }
  }
  return -1;
}

export function createMockD1Database(): D1Database {
  return new MockD1Database() as unknown as D1Database;
}
