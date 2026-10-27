-- A released (revoked) Workspace keeps only its record for history. Its
-- Workers and Allowed Folders are deleted so the same computer can register
-- again and publish them to its new Workspace. Releases now do this
-- themselves; this clears rows left by releases made before that change.
-- Worker scheduling and Space folder attachments cascade.
DELETE FROM workspace_worker_inventory
 WHERE workspace_id IN (
   SELECT id FROM execution_workspaces WHERE status = 'revoked'
 );
DELETE FROM workspace_allowed_folders
 WHERE workspace_id IN (
   SELECT id FROM execution_workspaces WHERE status = 'revoked'
 );
