-- V7 desktop pairing: one-time Workspace enrollment codes redeem into
-- a Workspace Runtime identity with its own bearer credential.
ALTER TABLE workspace_runtime_identities ADD COLUMN credential_token_hash TEXT;

CREATE UNIQUE INDEX idx_v7_workspace_runtime_token_hash
  ON workspace_runtime_identities(credential_token_hash)
  WHERE credential_token_hash IS NOT NULL;

CREATE INDEX idx_v7_workspace_runtime_active
  ON workspace_runtime_identities(workspace_id, revoked_at);
