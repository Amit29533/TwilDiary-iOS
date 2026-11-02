CREATE TABLE auth_attempts (
  id TEXT PRIMARY KEY NOT NULL,
  attempts INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX auth_attempts_expiry ON auth_attempts(expires_at);
