-- A Workspace installation has at most one live runtime credential. The
-- existing installation_id index remains in place as a second identity fence.
CREATE TABLE __migration_0004_runtime_identity_assertion (
  valid INTEGER NOT NULL CHECK (valid = 1)
);

-- Duplicate active credentials must be reviewed and revoked explicitly before
-- this invariant can be installed. Do not choose a winner during migration.
INSERT INTO __migration_0004_runtime_identity_assertion (valid)
SELECT CASE WHEN NOT EXISTS (
  SELECT workspace_id
    FROM workspace_runtime_identities
   WHERE revoked_at IS NULL
   GROUP BY workspace_id
  HAVING COUNT(*) > 1
)
THEN 1 ELSE 0 END;

DROP TABLE __migration_0004_runtime_identity_assertion;

CREATE UNIQUE INDEX idx_workspace_runtime_identities_active_workspace
  ON workspace_runtime_identities(workspace_id)
  WHERE revoked_at IS NULL;
