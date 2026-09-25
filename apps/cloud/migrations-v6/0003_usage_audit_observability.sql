-- V6-21: complete Workstream audit and metrics read models.
CREATE TABLE workstream_audit_log (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  actor_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN (
    'discussion.moderated', 'work_request.created', 'workflow.selected',
    'account.selected', 'checkout.provisioned', 'checkout.recovered',
    'lease.acquired', 'lease.released', 'checkpoint.created',
    'integration.updated'
  )),
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  occurred_at TEXT NOT NULL
);

CREATE INDEX idx_v6_workstream_audit_time
  ON workstream_audit_log(workstream_id, occurred_at);

CREATE TABLE workstream_observability_metrics (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  queue_wait_ms INTEGER NOT NULL DEFAULT 0,
  stateful_duration_ms INTEGER NOT NULL DEFAULT 0,
  checkout_recovery_attempted INTEGER NOT NULL DEFAULT 0,
  checkout_recovery_succeeded INTEGER NOT NULL DEFAULT 0,
  rollback_attempted INTEGER NOT NULL DEFAULT 0,
  rollback_succeeded INTEGER NOT NULL DEFAULT 0,
  workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  recorded_at TEXT NOT NULL
);

CREATE INDEX idx_v6_workstream_metrics_time
  ON workstream_observability_metrics(workstream_id, recorded_at);
