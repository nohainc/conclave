-- Pairing intents exist before a Workspace installation is claimed. Store
-- only a hash of the one-time code and create no execution_workspaces row.
CREATE TABLE workspace_pairing_intents (
  pairing_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  cancelled_at TEXT,
  claimed_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL
);

CREATE INDEX idx_v7_workspace_pairing_intents_owner
  ON workspace_pairing_intents(owner_user_id, created_at DESC);

CREATE INDEX idx_v7_workspace_pairing_intents_expiry
  ON workspace_pairing_intents(expires_at)
  WHERE used_at IS NULL AND cancelled_at IS NULL;

-- A stable desktop installation may own only one live runtime identity.
-- Revoked identities remain as attribution history and can be paired again.
ALTER TABLE workspace_runtime_identities ADD COLUMN installation_id TEXT;
CREATE UNIQUE INDEX idx_v7_runtime_installation_active
  ON workspace_runtime_identities(installation_id)
  WHERE installation_id IS NOT NULL AND revoked_at IS NULL;
