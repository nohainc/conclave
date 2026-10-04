-- Align production execution_workspaces and workspace_runtime_identities tables
-- and their indexes with the canonical v8 contract while preserving all existing rows.

CREATE TABLE __migration_0005_workspace_counts (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  workspaces_before INTEGER NOT NULL,
  identities_before INTEGER NOT NULL
);

INSERT INTO __migration_0005_workspace_counts (singleton, workspaces_before, identities_before)
VALUES (
  1,
  (SELECT COUNT(*) FROM execution_workspaces),
  (SELECT COUNT(*) FROM workspace_runtime_identities)
);

CREATE TABLE execution_workspaces__v8 (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'offline' CHECK (
    status IN ('online', 'offline', 'busy', 'draining', 'revoked')
  ),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, owner_user_id)
);

INSERT INTO execution_workspaces__v8 (id, owner_user_id, name, status, created_at, updated_at)
SELECT
  id,
  owner_user_id,
  name,
  CASE WHEN status = 'enrolled' THEN 'offline' ELSE status END,
  created_at,
  updated_at
FROM execution_workspaces;

DROP INDEX IF EXISTS idx_workspaces_owner;
DROP TABLE execution_workspaces;
ALTER TABLE execution_workspaces__v8 RENAME TO execution_workspaces;
CREATE INDEX idx_workspaces_owner ON execution_workspaces(owner_user_id);

CREATE TABLE workspace_runtime_identities__v8 (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  credential_token_hash TEXT NOT NULL,
  installation_id TEXT,
  created_at TEXT NOT NULL,
  revoked_at TEXT,
  CHECK (installation_id IS NOT NULL OR revoked_at IS NOT NULL)
);

INSERT INTO workspace_runtime_identities__v8 (
  id,
  workspace_id,
  credential_token_hash,
  installation_id,
  created_at,
  revoked_at
)
SELECT
  id,
  workspace_id,
  credential_token_hash,
  installation_id,
  created_at,
  revoked_at
FROM workspace_runtime_identities;

DROP INDEX IF EXISTS idx_v7_workspace_runtime_token_hash;
DROP INDEX IF EXISTS idx_v7_workspace_runtime_active;
DROP INDEX IF EXISTS idx_v7_runtime_installation_active;
DROP INDEX IF EXISTS idx_workspace_runtime_token_hash;
DROP INDEX IF EXISTS idx_workspace_runtime_active;
DROP INDEX IF EXISTS idx_runtime_installation_active;
DROP INDEX IF EXISTS idx_workspace_runtime_identities_active_workspace;

DROP TABLE workspace_runtime_identities;
ALTER TABLE workspace_runtime_identities__v8 RENAME TO workspace_runtime_identities;

CREATE UNIQUE INDEX idx_workspace_runtime_token_hash
  ON workspace_runtime_identities(credential_token_hash);

CREATE INDEX idx_workspace_runtime_active
  ON workspace_runtime_identities(workspace_id, revoked_at);

CREATE UNIQUE INDEX idx_runtime_installation_active
  ON workspace_runtime_identities(installation_id)
  WHERE revoked_at IS NULL;

CREATE UNIQUE INDEX idx_workspace_runtime_identities_active_workspace
  ON workspace_runtime_identities(workspace_id)
  WHERE revoked_at IS NULL;

CREATE TABLE __migration_0005_workspace_count_assertion (
  counts_match INTEGER NOT NULL CHECK (counts_match = 1)
);

INSERT INTO __migration_0005_workspace_count_assertion (counts_match)
SELECT CASE
  WHEN workspaces_before = (SELECT COUNT(*) FROM execution_workspaces)
   AND identities_before = (SELECT COUNT(*) FROM workspace_runtime_identities)
  THEN 1
  ELSE 0
END
FROM __migration_0005_workspace_counts;

DROP TABLE __migration_0005_workspace_count_assertion;
DROP TABLE __migration_0005_workspace_counts;
