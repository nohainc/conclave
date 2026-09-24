-- Conclave Architecture v6 clean D1 baseline.
-- Project is collaboration. Workspace is execution. Workstream is the unit
-- of discussion, workflow, and isolated execution inside a Project.
-- This baseline is intentionally independent: no v4/v5 compatibility views,
-- triggers, collaborative Workspace tables, or Host bindings are created.
PRAGMA foreign_keys = ON;

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  description TEXT,
  repository_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_v6_projects_owner ON projects(owner_user_id);

CREATE TABLE project_memberships (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'collaborator', 'viewer')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, user_id)
);
CREATE UNIQUE INDEX idx_v6_project_one_owner
  ON project_memberships(project_id) WHERE role = 'owner';

CREATE TABLE execution_workspaces (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'enrolled' CHECK (status IN ('enrolled', 'online', 'offline', 'busy', 'draining', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, owner_user_id)
);
CREATE INDEX idx_v6_workspaces_owner ON execution_workspaces(owner_user_id);

CREATE TABLE workspace_runtime_identities (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  credential_key_ref TEXT NOT NULL,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE workers (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'deprecated', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE ai_accounts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  execution_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('setup_required', 'ready', 'expired', 'error', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Workstream collaboration and access.
CREATE TABLE workstreams (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'paused', 'blocked', 'completed', 'archived')),
  access_policy_json TEXT NOT NULL DEFAULT '{}',
  lead_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_v6_workstreams_project ON workstreams(project_id, status);

CREATE TABLE workstream_memberships (
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('lead', 'contributor', 'viewer')),
  created_at TEXT NOT NULL,
  PRIMARY KEY (workstream_id, user_id)
);

CREATE TABLE discussion_messages (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  author_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body TEXT NOT NULL,
  references_json TEXT NOT NULL DEFAULT '[]',
  edited_at TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_v6_discussion_messages_workstream ON discussion_messages(workstream_id, created_at);

-- Versioned workflow contract.
CREATE TABLE workflow_definitions (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  current_version_id TEXT,
  created_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE workflow_versions (
  id TEXT PRIMARY KEY,
  workflow_definition_id TEXT NOT NULL REFERENCES workflow_definitions(id) ON DELETE CASCADE,
  version INTEGER NOT NULL CHECK (version > 0),
  created_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL,
  UNIQUE (workflow_definition_id, version)
);
CREATE UNIQUE INDEX idx_v6_workflow_current_version
  ON workflow_definitions(current_version_id);

CREATE TABLE workflow_steps (
  id TEXT PRIMARY KEY,
  workflow_version_id TEXT NOT NULL REFERENCES workflow_versions(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  role TEXT NOT NULL,
  required_capabilities_json TEXT NOT NULL DEFAULT '[]',
  execution_class TEXT NOT NULL CHECK (execution_class IN ('stateless_read', 'stateful_workstream')),
  step_order INTEGER NOT NULL CHECK (step_order >= 0),
  independent_from_json TEXT NOT NULL DEFAULT '[]',
  approval TEXT NOT NULL CHECK (approval IN ('none', 'human', 'project_owner')),
  timeout_ms INTEGER NOT NULL CHECK (timeout_ms >= 1000),
  output_contract_json TEXT NOT NULL DEFAULT '{}',
  UNIQUE (workflow_version_id, id),
  UNIQUE (workflow_version_id, step_order)
);

CREATE TABLE workflow_step_dependencies (
  workflow_version_id TEXT NOT NULL,
  step_id TEXT NOT NULL,
  depends_on_step_id TEXT NOT NULL,
  PRIMARY KEY (workflow_version_id, step_id, depends_on_step_id),
  CHECK (step_id <> depends_on_step_id),
  FOREIGN KEY (workflow_version_id, step_id)
    REFERENCES workflow_steps(workflow_version_id, id) ON DELETE CASCADE,
  FOREIGN KEY (workflow_version_id, depends_on_step_id)
    REFERENCES workflow_steps(workflow_version_id, id) ON DELETE CASCADE
);

CREATE TABLE workstream_execution_policies (
  workstream_id TEXT PRIMARY KEY REFERENCES workstreams(id) ON DELETE CASCADE,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  primary_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  require_checkout INTEGER NOT NULL DEFAULT 0 CHECK (require_checkout IN (0, 1)),
  max_concurrent_work_requests INTEGER NOT NULL CHECK (max_concurrent_work_requests > 0)
);

CREATE TABLE workstream_checkouts (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  repository_id TEXT NOT NULL,
  revision TEXT NOT NULL,
  relative_path TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('provisioning', 'ready', 'stale', 'deleted')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (workstream_id, id)
);
CREATE UNIQUE INDEX idx_v6_one_active_checkout
  ON workstream_checkouts(workstream_id)
  WHERE status IN ('provisioning', 'ready', 'stale');

CREATE TABLE work_requests (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  workflow_definition_id TEXT NOT NULL REFERENCES workflow_definitions(id) ON DELETE RESTRICT,
  workflow_version_id TEXT NOT NULL REFERENCES workflow_versions(id) ON DELETE RESTRICT,
  workflow_snapshot_json TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')),
  primary_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  checkout_id TEXT REFERENCES workstream_checkouts(id) ON DELETE RESTRICT,
  input_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_v6_work_requests_workstream ON work_requests(workstream_id, status, created_at);

CREATE TABLE workstream_execution_leases (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  checkout_id TEXT NOT NULL REFERENCES workstream_checkouts(id) ON DELETE RESTRICT,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
  status TEXT NOT NULL CHECK (status IN ('active', 'released', 'expired')),
  acquired_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  released_at TEXT,
  UNIQUE (checkout_id, fencing_token)
);
CREATE UNIQUE INDEX idx_v6_one_active_lease
  ON workstream_execution_leases(checkout_id) WHERE status = 'active';

CREATE TABLE workstream_checkpoints (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL,
  checkout_id TEXT NOT NULL,
  sequence INTEGER NOT NULL CHECK (sequence > 0),
  revision TEXT NOT NULL,
  summary TEXT NOT NULL,
  created_by_work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE RESTRICT,
  created_at TEXT NOT NULL,
  UNIQUE (checkout_id, sequence),
  FOREIGN KEY (workstream_id, checkout_id)
    REFERENCES workstream_checkouts(workstream_id, id) ON DELETE CASCADE
);

CREATE TABLE workstream_current_checkpoints (
  workstream_id TEXT PRIMARY KEY REFERENCES workstreams(id) ON DELETE CASCADE,
  checkpoint_id TEXT NOT NULL REFERENCES workstream_checkpoints(id) ON DELETE RESTRICT,
  updated_at TEXT NOT NULL
);

CREATE TABLE workstream_diff_artifacts (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  checkout_id TEXT NOT NULL REFERENCES workstream_checkouts(id) ON DELETE RESTRICT,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  revision TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'cancelled')),
  diff_text TEXT NOT NULL,
  created_at TEXT NOT NULL
);

-- Project execution records carry the full v6 correlation chain.
CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL,
  checkout_id TEXT REFERENCES workstream_checkouts(id) ON DELETE SET NULL,
  execution_lease_id TEXT REFERENCES workstream_execution_leases(id) ON DELETE SET NULL,
  status TEXT NOT NULL CHECK (status IN ('created', 'running', 'paused', 'completed', 'failed', 'cancelled')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE worker_assignments (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL,
  checkout_id TEXT REFERENCES workstream_checkouts(id) ON DELETE SET NULL,
  execution_lease_id TEXT REFERENCES workstream_execution_leases(id) ON DELETE SET NULL,
  execution_workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  runtime_identity_id TEXT NOT NULL REFERENCES workspace_runtime_identities(id) ON DELETE RESTRICT,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  account_id TEXT REFERENCES ai_accounts(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  input_json TEXT NOT NULL DEFAULT '{}',
  output_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE artifacts (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL,
  checkout_id TEXT REFERENCES workstream_checkouts(id) ON DELETE SET NULL,
  execution_lease_id TEXT REFERENCES workstream_execution_leases(id) ON DELETE SET NULL,
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  content_digest TEXT NOT NULL,
  storage_key TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE usage (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  workflow_version_id TEXT REFERENCES workflow_versions(id) ON DELETE SET NULL,
  checkout_id TEXT REFERENCES workstream_checkouts(id) ON DELETE SET NULL,
  execution_lease_id TEXT REFERENCES workstream_execution_leases(id) ON DELETE SET NULL,
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  requester_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  execution_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  worker_id TEXT REFERENCES workers(id) ON DELETE SET NULL,
  account_id TEXT REFERENCES ai_accounts(id) ON DELETE SET NULL,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_micros INTEGER,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  recorded_at TEXT NOT NULL
);

CREATE INDEX idx_v6_runs_workstream ON runs(workstream_id, created_at);
CREATE INDEX idx_v6_assignments_work_request ON worker_assignments(work_request_id, created_at);
CREATE INDEX idx_v6_artifacts_work_request ON artifacts(work_request_id, created_at);
CREATE INDEX idx_v6_usage_work_request ON usage(work_request_id, recorded_at);

-- Materialized, immutable-version task graph for the v6 Workflow runner.
CREATE TABLE workflow_tasks (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  workflow_version_id TEXT NOT NULL REFERENCES workflow_versions(id) ON DELETE RESTRICT,
  workflow_step_id TEXT NOT NULL,
  execution_class TEXT NOT NULL CHECK (execution_class IN ('stateless_read', 'stateful_workstream')),
  role TEXT NOT NULL,
  required_capabilities_json TEXT NOT NULL DEFAULT '[]',
  approval TEXT NOT NULL CHECK (approval IN ('none', 'human', 'project_owner')),
  timeout_ms INTEGER NOT NULL CHECK (timeout_ms >= 1000),
  output_contract_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('queued', 'running', 'waiting', 'completed', 'failed', 'cancelled')),
  attempt INTEGER NOT NULL DEFAULT 0 CHECK (attempt >= 0),
  output_json TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (work_request_id, workflow_step_id),
  FOREIGN KEY (workflow_version_id, workflow_step_id)
    REFERENCES workflow_steps(workflow_version_id, id) ON DELETE RESTRICT
);
CREATE TABLE workflow_task_dependencies (
  task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  depends_on_task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE RESTRICT,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);
CREATE INDEX idx_v6_workflow_tasks_request ON workflow_tasks(work_request_id, status, created_at);
