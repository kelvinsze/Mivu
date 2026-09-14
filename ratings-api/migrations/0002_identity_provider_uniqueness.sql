-- Prevent duplicate canonical identities when concurrent requests resolve by
-- TMDb or TVDb before either request has completed its insert.
CREATE UNIQUE INDEX IF NOT EXISTS idx_identity_tmdb_unique
ON media_identity(tmdb_id, media_type)
WHERE tmdb_id IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_identity_tvdb_unique
ON media_identity(tvdb_id, media_type)
WHERE tvdb_id IS NOT NULL;
