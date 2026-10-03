-- Ownership belongs to the stable installation, not to a rotatable runtime
-- credential. Existing runtime rows are used only to seed this independent
-- ownership record.

CREATE TABLE __migration_0003_workspace_installation_assertion (
  valid INTEGER NOT NULL CHECK (valid = 1)
);

-- Fail if legacy runtime history disagrees about either direction of the
-- installation/Workspace relationship, so the migration never chooses a
-- binding silently.
INSERT INTO __migration_0003_workspace_installation_assertion (valid)
SELECT CASE
  WHEN NOT EXISTS (
    SELECT i.installation_id
      FROM workspace_runtime_identities i
      JOIN execution_workspaces w ON w.id = i.workspace_id
     WHERE i.installation_id IS NOT NULL
     GROUP BY i.installation_id
    HAVING COUNT(DISTINCT i.workspace_id) > 1
        OR COUNT(DISTINCT w.owner_user_id) > 1
  )
  AND NOT EXISTS (
    SELECT i.workspace_id
      FROM workspace_runtime_identities i
     WHERE i.installation_id IS NOT NULL
     GROUP BY i.workspace_id
    HAVING COUNT(DISTINCT i.installation_id) > 1
  )
  THEN 1
  ELSE 0
END;

DROP TABLE __migration_0003_workspace_installation_assertion;

CREATE TABLE workspace_installations (
  installation_id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  status TEXT NOT NULL CHECK (status IN ('active', 'released')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  released_at TEXT,
  CHECK (
    (status = 'active' AND released_at IS NULL)
    OR (status = 'released' AND released_at IS NOT NULL)
  )
);

-- Disconnected and rotated runtime identities retain installation_id in the
-- deployed schema, so one record per stable installation preserves ownership
-- even when no runtime credential is currently active.
INSERT INTO workspace_installations (
  installation_id,
  owner_user_id,
  workspace_id,
  status,
  created_at,
  updated_at,
  released_at
)
SELECT
  i.installation_id,
  MAX(w.owner_user_id),
  MAX(i.workspace_id),
  'active',
  MIN(i.created_at),
  MAX(i.created_at),
  NULL
FROM workspace_runtime_identities i
JOIN execution_workspaces w ON w.id = i.workspace_id
WHERE i.installation_id IS NOT NULL
GROUP BY i.installation_id;

-- Ownership release clears installation_id from the runtime rows. Preserve
-- the latest released ownership from its audit event so account transfer stays
-- explicit after migration.
WITH release_events AS (
  SELECT
    CASE WHEN json_valid(a.details_json) = 1
      THEN json_extract(a.details_json, '$.installationId')
      ELSE NULL
    END AS installation_id,
    w.owner_user_id AS owner_user_id,
    a.workspace_id AS workspace_id,
    a.created_at AS released_at,
    ROW_NUMBER() OVER (
      PARTITION BY CASE WHEN json_valid(a.details_json) = 1
        THEN json_extract(a.details_json, '$.installationId')
        ELSE NULL
      END
      ORDER BY a.created_at DESC, a.id DESC
    ) AS event_rank
  FROM workspace_audit_log a
  JOIN execution_workspaces w ON w.id = a.workspace_id
  WHERE a.action = 'workspace.ownership.released'
    AND json_valid(a.details_json) = 1
    AND CASE WHEN json_valid(a.details_json) = 1
      THEN json_type(a.details_json, '$.installationId')
      ELSE NULL
    END = 'text'
    AND CASE WHEN json_valid(a.details_json) = 1
      THEN json_extract(a.details_json, '$.installationId')
      ELSE NULL
    END <> ''
)
INSERT INTO workspace_installations (
  installation_id,
  owner_user_id,
  workspace_id,
  status,
  created_at,
  updated_at,
  released_at
)
SELECT
  e.installation_id,
  e.owner_user_id,
  e.workspace_id,
  'released',
  e.released_at,
  e.released_at,
  e.released_at
FROM release_events e
WHERE e.event_rank = 1
  AND NOT EXISTS (
    SELECT 1 FROM workspace_installations wi
     WHERE wi.installation_id = e.installation_id
  );

CREATE TABLE __migration_0003_workspace_installation_backfill_assertion (
  valid INTEGER NOT NULL CHECK (valid = 1)
);

WITH legacy_installations AS (
  SELECT
    i.installation_id,
    MAX(i.workspace_id) AS workspace_id,
    MAX(w.owner_user_id) AS owner_user_id
  FROM workspace_runtime_identities i
  JOIN execution_workspaces w ON w.id = i.workspace_id
  WHERE i.installation_id IS NOT NULL
  GROUP BY i.installation_id
)
INSERT INTO __migration_0003_workspace_installation_backfill_assertion (valid)
SELECT CASE WHEN NOT EXISTS (
  SELECT 1
    FROM legacy_installations legacy
    LEFT JOIN workspace_installations wi
      ON wi.installation_id = legacy.installation_id
     AND wi.workspace_id = legacy.workspace_id
     AND wi.owner_user_id = legacy.owner_user_id
     AND wi.status = 'active'
   WHERE wi.installation_id IS NULL
)
THEN 1 ELSE 0 END;

DROP TABLE __migration_0003_workspace_installation_backfill_assertion;

CREATE UNIQUE INDEX idx_workspace_installations_active_workspace
  ON workspace_installations(workspace_id)
  WHERE status = 'active';
