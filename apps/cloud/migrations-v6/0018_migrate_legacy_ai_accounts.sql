-- EW-14: convert legacy AI Account identities into configured Workers.
--
-- This is intentionally metadata-only. The old v6 ai_accounts table does not
-- contain secret material; no credential value is copied into Cloud. A local
-- credential must be re-established through the configured Worker binding
-- when the legacy Account was not already ready on its Workspace.

INSERT OR IGNORE INTO configured_workers
  (id, owner_user_id, name, worker_type_id, status, default_model,
   config_json, concurrency_limit, cost_metadata_json, preferred_roles_json,
   allowed_roles_json, created_at, updated_at)
SELECT
  'configured-worker-' || a.id,
  a.owner_user_id,
  a.display_name || CASE
    WHEN COUNT(*) OVER (PARTITION BY a.owner_user_id, a.display_name) > 1
      OR EXISTS (
        SELECT 1 FROM configured_workers existing
         WHERE existing.owner_user_id = a.owner_user_id
           AND existing.name = a.display_name
      )
    THEN ' (legacy ' || substr(a.id, -8) || ')'
    ELSE ''
  END,
  a.worker_id,
  CASE a.status WHEN 'revoked' THEN 'revoked' ELSE 'active' END,
  NULL,
  json_object('migratedFrom', 'ai_accounts', 'legacyAccountId', a.id),
  1,
  NULL,
  '[]',
  '[]',
  a.created_at,
  a.updated_at
FROM ai_accounts a
JOIN users u ON u.id = a.owner_user_id
JOIN workers wt ON wt.id = a.worker_id
WHERE NOT EXISTS (
  SELECT 1 FROM configured_workers cw
   WHERE cw.id = 'configured-worker-' || a.id
);

INSERT OR IGNORE INTO worker_workspace_bindings
  (worker_id, workspace_id, enabled, desired_version_policy, local_readiness,
   package_status, credential_status, permissions_status, updated_at)
SELECT
  'configured-worker-' || a.id,
  a.execution_workspace_id,
  CASE WHEN a.status = 'revoked' THEN 0 ELSE 1 END,
  'stable',
  CASE a.status
    WHEN 'ready' THEN 'setup_required'
    WHEN 'revoked' THEN 'revoked'
    ELSE 'setup_required'
  END,
  'absent',
  CASE a.status
    WHEN 'expired' THEN 'expired'
    WHEN 'error' THEN 'error'
    WHEN 'revoked' THEN 'error'
    ELSE 'setup_required'
  END,
  'unknown',
  a.updated_at
FROM ai_accounts a
JOIN execution_workspaces ew ON ew.id = a.execution_workspace_id
WHERE NOT EXISTS (
  SELECT 1 FROM worker_workspace_bindings b
   WHERE b.worker_id = 'configured-worker-' || a.id
     AND b.workspace_id = a.execution_workspace_id
);

INSERT OR IGNORE INTO workspace_worker_credentials
  (id, worker_id, workspace_id, owner_user_id, auth_type, sharing_policy,
   provider_metadata_json, local_secret_ref, state, created_at, updated_at)
SELECT
  'credential-migrated-' || a.id,
  'configured-worker-' || a.id,
  a.execution_workspace_id,
  a.owner_user_id,
  'local',
  'private_only',
  json_object('migratedFrom', 'ai_accounts', 'legacyAccountId', a.id),
  NULL,
  CASE a.status
    WHEN 'ready' THEN 'setup_required'
    WHEN 'expired' THEN 'expired'
    WHEN 'error' THEN 'error'
    WHEN 'revoked' THEN 'revoked'
    ELSE 'setup_required'
  END,
  a.created_at,
  a.updated_at
FROM ai_accounts a
JOIN execution_workspaces ew ON ew.id = a.execution_workspace_id
WHERE NOT EXISTS (
  SELECT 1 FROM workspace_worker_credentials c
   WHERE c.worker_id = 'configured-worker-' || a.id
     AND c.workspace_id = a.execution_workspace_id
);

UPDATE worker_assignments
   SET configured_worker_id = (
     SELECT 'configured-worker-' || a.id
       FROM ai_accounts a
      WHERE a.id = worker_assignments.account_id
   )
 WHERE configured_worker_id IS NULL
   AND account_id IS NOT NULL
   AND EXISTS (
     SELECT 1 FROM ai_accounts a
      WHERE a.id = worker_assignments.account_id
   );

UPDATE usage
   SET configured_worker_id = (
         SELECT wa.configured_worker_id
           FROM worker_assignments wa
          WHERE wa.id = usage.assignment_id
       ),
       worker_type_id = (
         SELECT cw.worker_type_id
           FROM worker_assignments wa
           JOIN configured_workers cw ON cw.id = wa.configured_worker_id
          WHERE wa.id = usage.assignment_id
       ),
       credential_owner_user_id = COALESCE(
         credential_owner_user_id,
         account_owner_user_id
       )
 WHERE configured_worker_id IS NULL
   AND assignment_id IS NOT NULL;

INSERT INTO configured_worker_audit_log
  (id, configured_worker_id, workspace_id, actor_type, actor_id, action,
   target_id, details_json, created_at)
SELECT
  'configured-worker-audit-migrated-' || a.id,
  'configured-worker-' || a.id,
  a.execution_workspace_id,
  'system',
  'ew14-migration',
  'worker.created',
  'configured-worker-' || a.id,
  json_object('migratedFrom', 'ai_accounts', 'legacyAccountId', a.id),
  a.updated_at
FROM ai_accounts a
WHERE NOT EXISTS (
  SELECT 1 FROM configured_worker_audit_log l
   WHERE l.id = 'configured-worker-audit-migrated-' || a.id
);

INSERT INTO configured_worker_audit_log
  (id, configured_worker_id, workspace_id, actor_type, actor_id, action,
   target_id, details_json, created_at)
SELECT
  'configured-worker-audit-migrated-binding-' || a.id,
  'configured-worker-' || a.id,
  a.execution_workspace_id,
  'system',
  'ew14-migration',
  'worker.workspace.bound',
  'configured-worker-' || a.id || ':' || a.execution_workspace_id,
  json_object('migratedFrom', 'ai_accounts', 'legacyAccountId', a.id),
  a.updated_at
FROM ai_accounts a
JOIN execution_workspaces ew ON ew.id = a.execution_workspace_id
WHERE NOT EXISTS (
  SELECT 1 FROM configured_worker_audit_log l
   WHERE l.id = 'configured-worker-audit-migrated-binding-' || a.id
);
