-- Admit Chat without rewriting immutable Workflow snapshots.
-- D1 migrations execute atomically with foreign keys enabled.
-- Do not run individual statements or disable foreign keys.
PRAGMA defer_foreign_keys = ON;

-- Refuse schema drift rather than silently dropping extra columns or indexes.
CREATE TABLE __migration_0006_assertion (valid INTEGER NOT NULL CHECK (valid = 1));
INSERT INTO __migration_0006_assertion
SELECT CASE WHEN
  (SELECT COUNT(*) FROM pragma_table_info('work_requests')) = 14
  AND (SELECT COUNT(*) FROM pragma_table_info('workflow_tasks')) = 14
  AND (SELECT COUNT(*) FROM sqlite_schema WHERE type IN ('index', 'trigger')
       AND tbl_name IN ('work_requests', 'workflow_tasks') AND sql IS NOT NULL) = 3
  AND (SELECT COUNT(*) FROM sqlite_schema s, pragma_foreign_key_list(s.name) fk
       WHERE s.type = 'table' AND fk.[table] IN ('work_requests', 'workflow_tasks')) = 7
  AND NOT EXISTS (SELECT 1 FROM sqlite_schema WHERE type IN ('index', 'trigger')
       AND tbl_name IN ('work_requests', 'workflow_tasks') AND sql IS NOT NULL
       AND name NOT IN ('idx_work_requests_thread', 'idx_workflow_tasks_request', 'trg_work_requests_snapshot_immutable'))
  AND (SELECT group_concat(name || ':' || type || ':' || [notnull] || ':' || pk, '|') FROM pragma_table_info('work_requests')) = 'id:TEXT:0:1|thread_id:TEXT:1:0|requested_by_user_id:TEXT:1:0|mode:TEXT:1:0|workflow_id:TEXT:1:0|workflow_version:INTEGER:1:0|workflow_snapshot_json:TEXT:1:0|status:TEXT:1:0|primary_workspace_id:TEXT:0:0|input_json:TEXT:1:0|created_at:TEXT:1:0|updated_at:TEXT:1:0|snapshot_json:TEXT:1:0|cancel_requested_at:TEXT:0:0'
  AND (SELECT group_concat(name || ':' || type || ':' || [notnull] || ':' || pk, '|') FROM pragma_table_info('workflow_tasks')) = 'id:TEXT:0:1|work_request_id:TEXT:1:0|step_kind:TEXT:1:0|execution_mode:TEXT:1:0|timeout_ms:INTEGER:1:0|prompt_profile_version:TEXT:1:0|status:TEXT:1:0|attempt:INTEGER:1:0|output_json:TEXT:0:0|error:TEXT:0:0|created_at:TEXT:1:0|updated_at:TEXT:1:0|started_at:TEXT:0:0|finished_at:TEXT:0:0'
  AND (SELECT lower(replace(replace(replace(replace(sql, ' ', ''), char(10), ''), char(13), ''), char(9), '')) FROM sqlite_schema WHERE type = 'table' AND name = 'work_requests') IN ('createtablework_requests(idtextprimarykey,thread_idtextnotnullreferencesthreads(id)ondeletecascade,requested_by_user_idtextnotnullreferencesusers(id)ondeleterestrict,modetextnotnullcheck(modein(''stateless'',''stateful'')),workflow_idtextnotnullcheck(workflow_idin(''direct'',''research'',''plan_implement'',''implement_verify'',''full_cycle'')),workflow_versionintegernotnullcheck(workflow_version>0),workflow_snapshot_jsontextnotnull,statustextnotnullcheck(statusin(''queued'',''running'',''waiting'',''completed'',''failed'',''cancelled'')),primary_workspace_idtextreferencesexecution_workspaces(id)ondeleterestrict,input_jsontextnotnulldefault''{}'',created_attextnotnull,updated_attextnotnull,snapshot_jsontextnotnulldefault''{}'',cancel_requested_attext)', 'createtablework_requests(idtextprimarykey,thread_idtextnotnullreferencesthreads(id)ondeletecascade,requested_by_user_idtextnotnullreferencesusers(id)ondeleterestrict,modetextnotnullcheck(modein(''stateless'',''stateful'')),workflow_idtextnotnullcheck(workflow_idin(''chat'',''direct'',''research'',''plan_implement'',''implement_verify'',''full_cycle'')),workflow_versionintegernotnullcheck(workflow_version>0),workflow_snapshot_jsontextnotnull,statustextnotnullcheck(statusin(''queued'',''running'',''waiting'',''completed'',''failed'',''cancelled'')),primary_workspace_idtextreferencesexecution_workspaces(id)ondeleterestrict,input_jsontextnotnulldefault''{}'',created_attextnotnull,updated_attextnotnull,snapshot_jsontextnotnulldefault''{}'',cancel_requested_attext)')
  AND (SELECT lower(replace(replace(replace(replace(sql, ' ', ''), char(10), ''), char(13), ''), char(9), '')) FROM sqlite_schema WHERE type = 'table' AND name = 'workflow_tasks') IN ('createtableworkflow_tasks(idtextprimarykey,work_request_idtextnotnullreferenceswork_requests(id)ondeletecascade,step_kindtextnotnullcheck(step_kindin(''research'',''plan'',''implement'',''test'',''verify'')),execution_modetextnotnullcheck(execution_modein(''stateless_read'',''stateful_thread'')),timeout_msintegernotnullcheck(timeout_ms>=1000),prompt_profile_versiontextnotnull,statustextnotnullcheck(statusin(''queued'',''running'',''waiting'',''completed'',''failed'',''cancelled'')),attemptintegernotnulldefault0check(attempt>=0),output_jsontext,errortext,created_attextnotnull,updated_attextnotnull,started_attext,finished_attext,unique(work_request_id,step_kind))', 'createtableworkflow_tasks(idtextprimarykey,work_request_idtextnotnullreferenceswork_requests(id)ondeletecascade,step_kindtextnotnullcheck(step_kindin(''chat'',''research'',''plan'',''implement'',''test'',''verify'')),execution_modetextnotnullcheck(execution_modein(''stateless_read'',''stateful_thread'')),timeout_msintegernotnullcheck(timeout_ms>=1000),prompt_profile_versiontextnotnull,statustextnotnullcheck(statusin(''queued'',''running'',''waiting'',''completed'',''failed'',''cancelled'')),attemptintegernotnulldefault0check(attempt>=0),output_jsontext,errortext,created_attextnotnull,updated_attextnotnull,started_attext,finished_attext,unique(work_request_id,step_kind))')
  AND (SELECT lower(replace(replace(replace(replace(sql, ' ', ''), char(10), ''), char(13), ''), char(9), '')) FROM sqlite_schema WHERE type = 'index' AND name = 'idx_work_requests_thread') = 'createindexidx_work_requests_threadonwork_requests(thread_id,status,created_at)'
  AND (SELECT lower(replace(replace(replace(replace(sql, ' ', ''), char(10), ''), char(13), ''), char(9), '')) FROM sqlite_schema WHERE type = 'index' AND name = 'idx_workflow_tasks_request') = 'createindexidx_workflow_tasks_requestonworkflow_tasks(work_request_id,status,created_at)'
  AND (SELECT lower(replace(replace(replace(replace(sql, ' ', ''), char(10), ''), char(13), ''), char(9), '')) FROM sqlite_schema WHERE type = 'trigger' AND name = 'trg_work_requests_snapshot_immutable') = 'createtriggertrg_work_requests_snapshot_immutablebeforeupdateofthread_id,requested_by_user_id,mode,workflow_id,workflow_version,workflow_snapshot_json,snapshot_json,primary_workspace_id,input_jsononwork_requestswhenold.thread_idisnotnew.thread_idorold.requested_by_user_idisnotnew.requested_by_user_idorold.modeisnotnew.modeorold.workflow_idisnotnew.workflow_idorold.workflow_versionisnotnew.workflow_versionorold.workflow_snapshot_jsonisnotnew.workflow_snapshot_jsonorold.snapshot_jsonisnotnew.snapshot_jsonorold.primary_workspace_idisnotnew.primary_workspace_idorold.input_jsonisnotnew.input_jsonbeginselectraise(abort,''workrequestsnapshotsareimmutable'');end'
THEN 1 ELSE 0 END;

CREATE TABLE __migration_0006_work_requests AS SELECT * FROM work_requests;

CREATE TABLE __migration_0006_workflow_tasks AS SELECT * FROM workflow_tasks;

CREATE TABLE __migration_0006_workflow_task_dependencies AS SELECT * FROM workflow_task_dependencies;

CREATE TABLE __migration_0006_thread_runtime_leases AS SELECT * FROM thread_runtime_leases;

CREATE TABLE __migration_0006_runs AS SELECT id, work_request_id FROM runs;

CREATE TABLE __migration_0006_worker_assignments AS SELECT id, work_request_id FROM worker_assignments;

CREATE TABLE __migration_0006_artifacts AS SELECT id, work_request_id FROM artifacts;


-- Dependencies can RESTRICT dropping their referenced task. Save them first.
DELETE FROM workflow_task_dependencies;
DROP TABLE workflow_tasks;
DROP TABLE work_requests;

CREATE TABLE work_requests (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  workflow_id TEXT NOT NULL CHECK (
    workflow_id IN ('chat', 'direct', 'research', 'plan_implement', 'implement_verify', 'full_cycle')
  ),
  workflow_version INTEGER NOT NULL CHECK (workflow_version > 0),
  workflow_snapshot_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  primary_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  input_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  snapshot_json TEXT NOT NULL DEFAULT '{}',
  cancel_requested_at TEXT
);

CREATE TABLE workflow_tasks (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  step_kind TEXT NOT NULL CHECK (
    step_kind IN ('chat', 'research', 'plan', 'implement', 'test', 'verify')
  ),
  execution_mode TEXT NOT NULL CHECK (
    execution_mode IN ('stateless_read', 'stateful_thread')
  ),
  timeout_ms INTEGER NOT NULL CHECK (timeout_ms >= 1000),
  prompt_profile_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (
    status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')
  ),
  attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  output_json TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  UNIQUE (work_request_id, step_kind)
);

INSERT INTO work_requests SELECT * FROM __migration_0006_work_requests;
INSERT INTO workflow_tasks SELECT * FROM __migration_0006_workflow_tasks;
INSERT INTO workflow_task_dependencies SELECT * FROM __migration_0006_workflow_task_dependencies;
INSERT INTO thread_runtime_leases SELECT * FROM __migration_0006_thread_runtime_leases;

UPDATE runs SET work_request_id = (SELECT work_request_id FROM __migration_0006_runs saved WHERE saved.id = runs.id)
WHERE work_request_id IS NOT (SELECT work_request_id FROM __migration_0006_runs saved WHERE saved.id = runs.id);

UPDATE worker_assignments SET work_request_id = (SELECT work_request_id FROM __migration_0006_worker_assignments saved WHERE saved.id = worker_assignments.id)
WHERE work_request_id IS NOT (SELECT work_request_id FROM __migration_0006_worker_assignments saved WHERE saved.id = worker_assignments.id);

UPDATE artifacts SET work_request_id = (SELECT work_request_id FROM __migration_0006_artifacts saved WHERE saved.id = artifacts.id)
WHERE work_request_id IS NOT (SELECT work_request_id FROM __migration_0006_artifacts saved WHERE saved.id = artifacts.id);

CREATE INDEX idx_work_requests_thread
  ON work_requests(thread_id, status, created_at);
CREATE INDEX idx_workflow_tasks_request
  ON workflow_tasks(work_request_id, status, created_at);

CREATE TRIGGER trg_work_requests_snapshot_immutable
BEFORE UPDATE OF thread_id, requested_by_user_id, mode, workflow_id,
  workflow_version, workflow_snapshot_json, snapshot_json,
  primary_workspace_id, input_json
ON work_requests
WHEN OLD.thread_id IS NOT NEW.thread_id
  OR OLD.requested_by_user_id IS NOT NEW.requested_by_user_id
  OR OLD.mode IS NOT NEW.mode
  OR OLD.workflow_id IS NOT NEW.workflow_id
  OR OLD.workflow_version IS NOT NEW.workflow_version
  OR OLD.workflow_snapshot_json IS NOT NEW.workflow_snapshot_json
  OR OLD.snapshot_json IS NOT NEW.snapshot_json
  OR OLD.primary_workspace_id IS NOT NEW.primary_workspace_id
  OR OLD.input_json IS NOT NEW.input_json
BEGIN
  SELECT RAISE(ABORT, 'Work Request snapshots are immutable');
END;

-- Verify preservation and integrity before discarding backups.
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT * FROM work_requests EXCEPT SELECT * FROM __migration_0006_work_requests) AND NOT EXISTS (SELECT * FROM __migration_0006_work_requests EXCEPT SELECT * FROM work_requests) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT * FROM workflow_tasks EXCEPT SELECT * FROM __migration_0006_workflow_tasks) AND NOT EXISTS (SELECT * FROM __migration_0006_workflow_tasks EXCEPT SELECT * FROM workflow_tasks) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT * FROM workflow_task_dependencies EXCEPT SELECT * FROM __migration_0006_workflow_task_dependencies) AND NOT EXISTS (SELECT * FROM __migration_0006_workflow_task_dependencies EXCEPT SELECT * FROM workflow_task_dependencies) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT * FROM thread_runtime_leases EXCEPT SELECT * FROM __migration_0006_thread_runtime_leases) AND NOT EXISTS (SELECT * FROM __migration_0006_thread_runtime_leases EXCEPT SELECT * FROM thread_runtime_leases) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT id, work_request_id FROM runs EXCEPT SELECT * FROM __migration_0006_runs) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT id, work_request_id FROM worker_assignments EXCEPT SELECT * FROM __migration_0006_worker_assignments) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT id, work_request_id FROM artifacts EXCEPT SELECT * FROM __migration_0006_artifacts) THEN 1 ELSE 0 END;
INSERT INTO __migration_0006_assertion SELECT CASE WHEN NOT EXISTS (SELECT * FROM pragma_foreign_key_check) THEN 1 ELSE 0 END;

DROP TABLE __migration_0006_work_requests;

DROP TABLE __migration_0006_workflow_tasks;

DROP TABLE __migration_0006_workflow_task_dependencies;

DROP TABLE __migration_0006_thread_runtime_leases;

DROP TABLE __migration_0006_runs;

DROP TABLE __migration_0006_worker_assignments;

DROP TABLE __migration_0006_artifacts;

DROP TABLE __migration_0006_assertion;

PRAGMA defer_foreign_keys = OFF;
