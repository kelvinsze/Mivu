-- Migration 0001_initial.sql: Create media_identity and ratings_cache tables

CREATE TABLE IF NOT EXISTS media_identity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    media_type TEXT NOT NULL, -- 'movie' or 'tv'

    imdb_id TEXT,
    tmdb_id INTEGER,
    tvdb_id INTEGER,
    douban_id TEXT,

    title TEXT,
    original_title TEXT,
    year INTEGER,

    douban_match_confidence REAL,
    douban_match_source TEXT, -- 'auto', 'manual', 'external'

    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_identity_imdb
ON media_identity(imdb_id)
WHERE imdb_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_identity_tmdb
ON media_identity(tmdb_id, media_type);

CREATE INDEX IF NOT EXISTS idx_identity_douban
ON media_identity(douban_id);

CREATE TABLE IF NOT EXISTS ratings_cache (
    id INTEGER PRIMARY KEY AUTOINCREMENT,

    identity_id INTEGER NOT NULL,

    provider TEXT NOT NULL, -- 'mdblist', 'douban'

    payload TEXT NOT NULL,

    fetched_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,

    FOREIGN KEY(identity_id)
        REFERENCES media_identity(id)
        ON DELETE CASCADE
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_rating_provider
ON ratings_cache(identity_id, provider);

CREATE INDEX IF NOT EXISTS idx_ratings_cache_expires
ON ratings_cache(expires_at);
