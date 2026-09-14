export interface RatingsCacheRow {
  id: number;
  identity_id: number;
  provider: string;
  payload: string;
  fetched_at: string;
  expires_at: string;
}

export interface CachedRatingEntry {
  provider: string;
  payload: string;
  fetchedAt: string;
  expiresAt: string;
  isFresh: boolean;
  isStale: boolean;
}

export async function getCachedRating(
  db: D1Database,
  identityId: number,
  provider: string
): Promise<CachedRatingEntry | null> {
  const row = await db
    .prepare('SELECT * FROM ratings_cache WHERE identity_id = ? AND provider = ? LIMIT 1')
    .bind(identityId, provider)
    .first<RatingsCacheRow>();

  if (!row) return null;

  const now = new Date().getTime();
  const expiresTime = new Date(row.expires_at).getTime();
  const fetchedTime = new Date(row.fetched_at).getTime();

  // Fresh if current time is before expires_at
  const isFresh = now < expiresTime;
  // Stale if past expires_at but within 30 days of fetched_at (or custom stale limit)
  const isStale = !isFresh && now - fetchedTime < 30 * 24 * 60 * 60 * 1000;

  return {
    provider: row.provider,
    payload: row.payload,
    fetchedAt: row.fetched_at,
    expiresAt: row.expires_at,
    isFresh,
    isStale,
  };
}

export async function getAllCachedRatings(
  db: D1Database,
  identityId: number
): Promise<Map<string, CachedRatingEntry>> {
  const { results } = await db
    .prepare('SELECT * FROM ratings_cache WHERE identity_id = ?')
    .bind(identityId)
    .all<RatingsCacheRow>();

  const map = new Map<string, CachedRatingEntry>();
  if (!results) return map;

  const now = new Date().getTime();

  for (const row of results) {
    const expiresTime = new Date(row.expires_at).getTime();
    const fetchedTime = new Date(row.fetched_at).getTime();
    const isFresh = now < expiresTime;
    const isStale = !isFresh && now - fetchedTime < 30 * 24 * 60 * 60 * 1000;

    map.set(row.provider, {
      provider: row.provider,
      payload: row.payload,
      fetchedAt: row.fetched_at,
      expiresAt: row.expires_at,
      isFresh,
      isStale,
    });
  }

  return map;
}

export async function upsertCachedRating(
  db: D1Database,
  identityId: number,
  provider: string,
  payload: string,
  expiresAt: string,
  fetchedAt?: string
): Promise<void> {
  const now = fetchedAt || new Date().toISOString();

  await db
    .prepare(
      `INSERT INTO ratings_cache (identity_id, provider, payload, fetched_at, expires_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(identity_id, provider) DO UPDATE SET
         payload = excluded.payload,
         fetched_at = excluded.fetched_at,
         expires_at = excluded.expires_at`
    )
    .bind(identityId, provider, payload, now, expiresAt)
    .run();
}

export async function deleteCachedRatings(
  db: D1Database,
  identityId: number,
  provider?: string
): Promise<void> {
  if (provider) {
    await db
      .prepare('DELETE FROM ratings_cache WHERE identity_id = ? AND provider = ?')
      .bind(identityId, provider)
      .run();
  } else {
    await db
      .prepare('DELETE FROM ratings_cache WHERE identity_id = ?')
      .bind(identityId)
      .run();
  }
}
