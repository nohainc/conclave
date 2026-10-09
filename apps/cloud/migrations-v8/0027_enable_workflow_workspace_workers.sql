-- Workflow Workspace selection is the user-facing execution authorization.
-- Make ready, locally enabled Workers in selected Workspaces schedulable so
-- Workflows do not require a separate hidden scheduling control.
PRAGMA defer_foreign_keys = ON;

INSERT INTO worker_scheduling_audit(
  id, worker_id, actor_user_id, action, requested_at, completed_at, details_json
)
SELECT lower(hex(randomblob(16))), ws.worker_id, NULL, 'enabled', datetime('now'),
       datetime('now'), '{"reason":"workflow_workspace_selection"}'
  FROM worker_scheduling ws
  JOIN workspace_worker_inventory i ON i.worker_id = ws.worker_id
 WHERE ws.state <> 'enabled'
   AND ws.state <> 'draining'
   AND i.activation_state = 'enabled'
   AND i.readiness_state = 'ready'
   AND (
     EXISTS (
       SELECT 1 FROM user_workflow_settings u
        WHERE u.workspace_id = i.workspace_id
     )
     OR EXISTS (
       SELECT 1 FROM space_workflow_settings s
        WHERE s.workspace_id = i.workspace_id
     )
   );

UPDATE worker_scheduling
   SET state = 'enabled', updated_at = datetime('now')
 WHERE state <> 'enabled'
   AND state <> 'draining'
   AND worker_id IN (
     SELECT i.worker_id
       FROM workspace_worker_inventory i
      WHERE i.activation_state = 'enabled'
        AND i.readiness_state = 'ready'
        AND (
          EXISTS (
            SELECT 1 FROM user_workflow_settings u
             WHERE u.workspace_id = i.workspace_id
          )
          OR EXISTS (
            SELECT 1 FROM space_workflow_settings s
             WHERE s.workspace_id = i.workspace_id
          )
        )
   );

PRAGMA defer_foreign_keys = OFF;
