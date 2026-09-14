import { MediaIdentity, MediaType } from '../types/env';

interface IdentityRow {
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

function mapRowToIdentity(row: IdentityRow): MediaIdentity {
  return {
    id: row.id,
    mediaType: row.media_type as MediaType,
    imdbId: row.imdb_id,
    tmdbId: row.tmdb_id,
    tvdbId: row.tvdb_id,
    doubanId: row.douban_id,
    title: row.title,
    originalTitle: row.original_title,
    year: row.year,
    doubanMatchConfidence: row.douban_match_confidence,
    doubanMatchSource: row.douban_match_source as 'auto' | 'manual' | 'external' | null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export async function findIdentityByImdb(db: D1Database, imdbId: string): Promise<MediaIdentity | null> {
  const row = await db
    .prepare('SELECT * FROM media_identity WHERE imdb_id = ? LIMIT 1')
    .bind(imdbId)
    .first<IdentityRow>();

  return row ? mapRowToIdentity(row) : null;
}

export async function findIdentityByTmdb(
  db: D1Database,
  tmdbId: number,
  mediaType: MediaType
): Promise<MediaIdentity | null> {
  const row = await db
    .prepare('SELECT * FROM media_identity WHERE tmdb_id = ? AND media_type = ? LIMIT 1')
    .bind(tmdbId, mediaType)
    .first<IdentityRow>();

  return row ? mapRowToIdentity(row) : null;
}

export async function findIdentityByTvdb(
  db: D1Database,
  tvdbId: number,
  mediaType: MediaType
): Promise<MediaIdentity | null> {
  const row = await db
    .prepare('SELECT * FROM media_identity WHERE tvdb_id = ? AND media_type = ? LIMIT 1')
    .bind(tvdbId, mediaType)
    .first<IdentityRow>();

  return row ? mapRowToIdentity(row) : null;
}

export async function findIdentityByDouban(db: D1Database, doubanId: string): Promise<MediaIdentity | null> {
  const row = await db
    .prepare('SELECT * FROM media_identity WHERE douban_id = ? LIMIT 1')
    .bind(doubanId)
    .first<IdentityRow>();

  return row ? mapRowToIdentity(row) : null;
}

export async function createIdentity(db: D1Database, identity: Partial<MediaIdentity>): Promise<MediaIdentity> {
  const now = new Date().toISOString();
  const mediaType = identity.mediaType || 'movie';

  const result = await db
    .prepare(
      `INSERT INTO media_identity (
        media_type, imdb_id, tmdb_id, tvdb_id, douban_id,
        title, original_title, year,
        douban_match_confidence, douban_match_source,
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .bind(
      mediaType,
      identity.imdbId ?? null,
      identity.tmdbId ?? null,
      identity.tvdbId ?? null,
      identity.doubanId ?? null,
      identity.title ?? null,
      identity.originalTitle ?? null,
      identity.year ?? null,
      identity.doubanMatchConfidence ?? null,
      identity.doubanMatchSource ?? null,
      now,
      now
    )
    .run();

  const id = result.meta?.last_row_id as number;

  return {
    id,
    mediaType,
    imdbId: identity.imdbId ?? null,
    tmdbId: identity.tmdbId ?? null,
    tvdbId: identity.tvdbId ?? null,
    doubanId: identity.doubanId ?? null,
    title: identity.title ?? null,
    originalTitle: identity.originalTitle ?? null,
    year: identity.year ?? null,
    doubanMatchConfidence: identity.doubanMatchConfidence ?? null,
    doubanMatchSource: identity.doubanMatchSource ?? null,
    createdAt: now,
    updatedAt: now,
  };
}

export async function updateIdentity(
  db: D1Database,
  id: number,
  updates: Partial<MediaIdentity>
): Promise<MediaIdentity | null> {
  const now = new Date().toISOString();

  const fields: string[] = ['updated_at = ?'];
  const values: unknown[] = [now];

  if (updates.mediaType !== undefined) {
    fields.push('media_type = ?');
    values.push(updates.mediaType);
  }
  if (updates.imdbId !== undefined) {
    fields.push('imdb_id = ?');
    values.push(updates.imdbId);
  }
  if (updates.tmdbId !== undefined) {
    fields.push('tmdb_id = ?');
    values.push(updates.tmdbId);
  }
  if (updates.tvdbId !== undefined) {
    fields.push('tvdb_id = ?');
    values.push(updates.tvdbId);
  }
  if (updates.doubanId !== undefined) {
    fields.push('douban_id = ?');
    values.push(updates.doubanId);
  }
  if (updates.title !== undefined) {
    fields.push('title = ?');
    values.push(updates.title);
  }
  if (updates.originalTitle !== undefined) {
    fields.push('original_title = ?');
    values.push(updates.originalTitle);
  }
  if (updates.year !== undefined) {
    fields.push('year = ?');
    values.push(updates.year);
  }
  if (updates.doubanMatchConfidence !== undefined) {
    fields.push('douban_match_confidence = ?');
    values.push(updates.doubanMatchConfidence);
  }
  if (updates.doubanMatchSource !== undefined) {
    fields.push('douban_match_source = ?');
    values.push(updates.doubanMatchSource);
  }

  values.push(id);

  await db
    .prepare(`UPDATE media_identity SET ${fields.join(', ')} WHERE id = ?`)
    .bind(...values)
    .run();

  const row = await db.prepare('SELECT * FROM media_identity WHERE id = ? LIMIT 1').bind(id).first<IdentityRow>();
  return row ? mapRowToIdentity(row) : null;
}
