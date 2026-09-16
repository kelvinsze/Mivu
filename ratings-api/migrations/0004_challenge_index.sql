-- Index on expires_at for efficient challenge cleanup queries.
CREATE INDEX IF NOT EXISTS idx_challenges_expires ON app_attest_challenges(expires_at);
