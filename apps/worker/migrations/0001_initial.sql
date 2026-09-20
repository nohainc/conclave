PRAGMA foreign_keys = ON;

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  repository_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE workers (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('model', 'agent', 'runtime', 'ci', 'tool', 'human')),
  adapter_version TEXT NOT NULL,
  roles_json TEXT NOT NULL,
  capabilities_json TEXT NOT NULL,
  permissions_json TEXT NOT NULL,
  independence_key TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE goals (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id),
  original_message TEXT NOT NULL,
  objective TEXT NOT NULL,
  constraints_json TEXT NOT NULL,
  completion_criteria_json TEXT NOT NULL,
  verification_policy_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  goal_id TEXT NOT NULL REFERENCES goals(id),
  parent_run_id TEXT REFERENCES runs(id),
  policy_snapshot_json TEXT NOT NULL,
  current_phase_id TEXT,
  status TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE phases (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  name TEXT NOT NULL,
  purpose TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (run_id, sequence)
);

CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  phase_id TEXT NOT NULL REFERENCES phases(id),
  objective TEXT NOT NULL,
  role TEXT NOT NULL,
  capabilities_json TEXT NOT NULL,
  input_json TEXT NOT NULL,
  output_contract_json TEXT NOT NULL,
  status TEXT NOT NULL,
  requires_independent_verification INTEGER NOT NULL DEFAULT 0 CHECK (requires_independent_verification IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE task_dependencies (
  task_id TEXT NOT NULL REFERENCES tasks(id),
  depends_on_task_id TEXT NOT NULL REFERENCES tasks(id),
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

CREATE TABLE attempts (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id),
  worker_id TEXT NOT NULL REFERENCES workers(id),
  attempt_number INTEGER NOT NULL,
  input_snapshot_json TEXT NOT NULL,
  output_artifact_ids_json TEXT NOT NULL,
  status TEXT NOT NULL,
  failure_class TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  UNIQUE (task_id, attempt_number)
);

CREATE TABLE model_calls (
  id TEXT PRIMARY KEY,
  attempt_id TEXT NOT NULL REFERENCES attempts(id),
  worker_id TEXT NOT NULL REFERENCES workers(id),
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  request_artifact_id TEXT,
  response_artifact_id TEXT,
  status TEXT NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at TEXT NOT NULL,
  finished_at TEXT
);

CREATE TABLE findings (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  task_id TEXT REFERENCES tasks(id),
  source_attempt_id TEXT REFERENCES attempts(id),
  severity TEXT NOT NULL CHECK (severity IN ('blocker', 'major', 'minor', 'note')),
  scope TEXT NOT NULL,
  description TEXT NOT NULL,
  evidence_artifact_ids_json TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE verifications (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  task_id TEXT REFERENCES tasks(id),
  criterion_id TEXT NOT NULL,
  verifier_worker_id TEXT REFERENCES workers(id),
  method TEXT NOT NULL,
  outcome TEXT NOT NULL,
  evidence_artifact_ids_json TEXT NOT NULL,
  rationale TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE artifacts (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  task_id TEXT REFERENCES tasks(id),
  attempt_id TEXT REFERENCES attempts(id),
  media_type TEXT NOT NULL,
  storage_kind TEXT NOT NULL CHECK (storage_kind IN ('inline', 'r2')),
  inline_payload TEXT,
  r2_bucket TEXT,
  r2_key TEXT,
  content_digest TEXT NOT NULL,
  size_bytes INTEGER NOT NULL,
  provenance_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  CHECK ((storage_kind = 'inline' AND inline_payload IS NOT NULL AND r2_key IS NULL) OR
         (storage_kind = 'r2' AND inline_payload IS NULL AND r2_bucket IS NOT NULL AND r2_key IS NOT NULL))
);

CREATE TABLE run_events (
  run_id TEXT NOT NULL REFERENCES runs(id),
  sequence INTEGER NOT NULL,
  id TEXT NOT NULL UNIQUE,
  event_type TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  PRIMARY KEY (run_id, sequence)
);

CREATE TABLE usage (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id),
  attempt_id TEXT REFERENCES attempts(id),
  worker_id TEXT REFERENCES workers(id),
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  execution_ms INTEGER NOT NULL DEFAULT 0,
  estimated_cost_micros INTEGER NOT NULL DEFAULT 0,
  recorded_at TEXT NOT NULL
);

CREATE INDEX idx_goals_project ON goals(project_id);
CREATE INDEX idx_runs_goal ON runs(goal_id);
CREATE INDEX idx_phases_run ON phases(run_id, sequence);
CREATE INDEX idx_tasks_phase ON tasks(phase_id);
CREATE INDEX idx_attempts_task ON attempts(task_id, attempt_number);
CREATE INDEX idx_model_calls_attempt ON model_calls(attempt_id);
CREATE INDEX idx_findings_run ON findings(run_id, status);
CREATE INDEX idx_verifications_run ON verifications(run_id, criterion_id);
CREATE INDEX idx_artifacts_run ON artifacts(run_id, created_at);
CREATE INDEX idx_events_run ON run_events(run_id, sequence);
CREATE INDEX idx_usage_run ON usage(run_id, recorded_at);
