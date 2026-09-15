-- Attested device keys and one-time challenges for App Attest.
CREATE TABLE IF NOT EXISTS app_attest_keys (
    key_id TEXT PRIMARY KEY,
    public_key_spki BLOB NOT NULL,
    assertion_counter INTEGER NOT NULL DEFAULT 0,
    environment TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_used_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS app_attest_challenges (
    id TEXT PRIMARY KEY,
    purpose TEXT NOT NULL,
    key_id TEXT,
    challenge_b64 TEXT NOT NULL,
    expires_at INTEGER NOT NULL
);
