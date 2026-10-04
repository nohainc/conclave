-- Align production Workspace runtime indexes with the canonical v8 contract.
-- idx_runtime_installation_active enforces at most one unrevoked runtime
-- identity per installation_id.

CREATE TABLE __migration_0005_runtime_index_assertion (
  valid INTEGER NOT NULL CHECK (valid = 1)
);

-- Assert no duplicate unrevoked runtime identities exist for the same installation_id
INSERT INTO __migration_0005_runtime_index_assertion (valid)
SELECT CASE WHEN NOT EXISTS (
  SELECT installation_id
    FROM workspace_runtime_identities
   WHERE installation_id IS NOT NULL
     AND revoked_at IS NULL
   GROUP BY installation_id
  HAVING COUNT(*) > 1
)
THEN 1 ELSE 0 END;

DROP TABLE __migration_0005_runtime_index_assertion;

CREATE UNIQUE INDEX IF NOT EXISTS idx_runtime_installation_active
  ON workspace_runtime_identities(installation_id)
  WHERE revoked_at IS NULL;
