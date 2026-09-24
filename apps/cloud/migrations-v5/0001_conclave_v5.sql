-- Conclave AX Architecture v5 clean D1 baseline.
--
-- Project is collaboration. execution_workspaces are execution environments.
-- This is a fresh pre-production baseline; it intentionally contains no
-- compatibility views, triggers, or v4 collaborative Workspace tables.
PRAGMA foreign_keys = ON;

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  avatar_url TEXT,
  email_verified INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE auth_accounts (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL,
  provider_id TEXT NOT NULL,
  access_token TEXT,
  refresh_token TEXT,
  id_token TEXT,
  access_token_expires_at TEXT,
  refresh_token_expires_at TEXT,
  scope TEXT,
  password TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (provider_id, account_id)
);
CREATE INDEX idx_auth_accounts_user ON auth_accounts(user_id);

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  ip_address TEXT,
  user_agent TEXT
);
CREATE INDEX idx_auth_sessions_user ON auth_sessions(user_id);

CREATE TABLE auth_verifications (
  id TEXT PRIMARY KEY,
  identifier TEXT NOT NULL,
  value TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE passkeys (
  id TEXT PRIMARY KEY,
  name TEXT,
  public_key TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  credential_id TEXT NOT NULL UNIQUE,
  counter INTEGER NOT NULL DEFAULT 0,
  device_type TEXT NOT NULL,
  backed_up INTEGER NOT NULL DEFAULT 0 CHECK (backed_up IN (0, 1)),
  transports TEXT,
  created_at TEXT,
  aaguid TEXT
);
CREATE INDEX idx_passkeys_user ON passkeys(user_id);

CREATE TABLE auth_step_up_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  method TEXT NOT NULL CHECK (method IN ('passkey', 'totp')),
  created_at TEXT NOT NULL,
  consumed_at TEXT
);

CREATE TABLE auth_step_up_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,
  method TEXT NOT NULL CHECK (method IN ('passkey', 'totp')),
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  UNIQUE (session_id)
);

CREATE TABLE auth_audit_events (
  id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  session_id TEXT,
  action TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'denied')),
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

-- Collaboration boundary. Projects have one owner and no Workspace foreign key.
CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  description TEXT,
  repository_id TEXT,
  settings_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, owner_user_id)
);
CREATE INDEX idx_projects_owner ON projects(owner_user_id);

CREATE TABLE project_memberships (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'collaborator', 'viewer')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, user_id)
);
CREATE UNIQUE INDEX idx_project_one_owner
  ON project_memberships(project_id) WHERE role = 'owner';
CREATE INDEX idx_project_memberships_user ON project_memberships(user_id);

CREATE TABLE project_invitations (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('collaborator', 'viewer')),
  token_hash TEXT NOT NULL UNIQUE,
  invited_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  accepted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_project_invitations_project ON project_invitations(project_id, status);

CREATE TABLE project_execution_preferences (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,
  preferred_worker_ids_json TEXT NOT NULL DEFAULT '[]',
  preferred_model_ids_json TEXT NOT NULL DEFAULT '[]',
  preferred_account_ids_json TEXT NOT NULL DEFAULT '[]',
  quality TEXT NOT NULL DEFAULT 'balanced' CHECK (quality IN ('fast', 'balanced', 'high')),
  budget_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Execution boundary. One Workspace is owned by one User and one runtime.
CREATE TABLE execution_workspaces (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'enrolled' CHECK (status IN ('enrolled', 'online', 'offline', 'busy', 'draining', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, owner_user_id)
);
CREATE INDEX idx_execution_workspaces_owner ON execution_workspaces(owner_user_id);

CREATE TABLE workspace_runtime_identities (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  machine_fingerprint TEXT NOT NULL UNIQUE,
  platform TEXT NOT NULL CHECK (platform IN ('macos', 'linux', 'windows')),
  architecture TEXT NOT NULL CHECK (architecture IN ('arm64', 'x64')),
  credential_key_ref TEXT NOT NULL,
  credential_token_hash TEXT NOT NULL UNIQUE,
  created_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE TABLE workspace_enrollments (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  expires_at TEXT NOT NULL,
  used_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE workspace_sessions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  runtime_identity_id TEXT NOT NULL REFERENCES workspace_runtime_identities(id) ON DELETE CASCADE,
  client_version TEXT NOT NULL,
  protocol_version TEXT NOT NULL,
  ip_address TEXT,
  connected_at TEXT NOT NULL,
  last_heartbeat_at TEXT NOT NULL,
  disconnected_at TEXT
);
CREATE INDEX idx_workspace_sessions_workspace ON workspace_sessions(workspace_id);

CREATE TABLE workspace_releases (
  version TEXT PRIMARY KEY,
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta', 'development')),
  min_supported_version TEXT,
  supported_os_json TEXT NOT NULL DEFAULT '["macos","linux","windows"]',
  supported_arch_json TEXT NOT NULL DEFAULT '["arm64","x64"]',
  package_digest TEXT NOT NULL,
  package_r2_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  release_notes TEXT,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE workers (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  publisher TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('active', 'deprecated', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE worker_versions (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  version TEXT NOT NULL,
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta', 'development')),
  protocol_version TEXT NOT NULL,
  supported_os_json TEXT NOT NULL,
  supported_arch_json TEXT NOT NULL,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  permissions_json TEXT NOT NULL DEFAULT '[]',
  entrypoint TEXT NOT NULL,
  package_digest TEXT NOT NULL,
  package_r2_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (worker_id, version),
  UNIQUE (id, worker_id)
);

CREATE TABLE workspace_worker_installations (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  worker_version_id TEXT NOT NULL,
  resolved_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('absent', 'requested', 'installing', 'ready', 'updating', 'degraded', 'failed', 'removing')),
  error TEXT,
  installed_at TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id, worker_id),
  FOREIGN KEY (worker_version_id, worker_id) REFERENCES worker_versions(id, worker_id)
);

CREATE TABLE workspace_worker_desired_state (
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  version_policy TEXT NOT NULL DEFAULT 'latest',
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  updated_at TEXT NOT NULL,
  PRIMARY KEY (workspace_id, worker_id)
);

-- AI Accounts are User-owned. A local placement is not ownership or sharing.
CREATE TABLE ai_accounts (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  execution_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE SET NULL,
  display_name TEXT NOT NULL,
  auth_type TEXT NOT NULL CHECK (auth_type IN ('none', 'api_key', 'oauth', 'session_token', 'local')),
  secret_location TEXT NOT NULL CHECK (secret_location IN ('none', 'workspace_secure_store')),
  secret_reference TEXT,
  status TEXT NOT NULL CHECK (status IN ('setup_required', 'ready', 'expired', 'error', 'revoked')),
  sharing_mode TEXT NOT NULL DEFAULT 'private_only' CHECK (sharing_mode IN ('private_only', 'project_shared')),
  provider_metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK ((secret_location = 'workspace_secure_store' AND secret_reference IS NOT NULL) OR secret_location = 'none')
);
CREATE INDEX idx_ai_accounts_owner ON ai_accounts(owner_user_id, status);

CREATE TABLE workspace_project_grants (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL,
  granted_by_user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked', 'expired')),
  scope TEXT NOT NULL CHECK (scope IN ('project_repository', 'selected_paths', 'full_workspace')),
  repository_mappings_json TEXT NOT NULL DEFAULT '[]',
  path_mappings_json TEXT NOT NULL DEFAULT '[]',
  allowed_worker_ids_json TEXT NOT NULL DEFAULT '[]',
  allowed_worker_capabilities_json TEXT NOT NULL DEFAULT '[]',
  allowed_permissions_json TEXT NOT NULL DEFAULT '[]',
  network_policy_json TEXT NOT NULL DEFAULT '{"mode":"deny_all","allowedHosts":[]}',
  concurrency_json TEXT NOT NULL DEFAULT '{"maxConcurrentAssignments":1}',
  budget_json TEXT,
  requires_step_up INTEGER NOT NULL DEFAULT 0 CHECK (requires_step_up IN (0, 1)),
  expires_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, project_id, workspace_id),
  FOREIGN KEY (workspace_id, granted_by_user_id) REFERENCES execution_workspaces(id, owner_user_id)
);
CREATE INDEX idx_workspace_project_grants_project ON workspace_project_grants(project_id, status);
CREATE INDEX idx_workspace_project_grants_workspace ON workspace_project_grants(workspace_id, status);

CREATE TABLE project_account_grants (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL REFERENCES ai_accounts(id) ON DELETE CASCADE,
  granted_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  grantee_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'revoked', 'expired')),
  expires_at TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (project_id, account_id, grantee_user_id)
);
CREATE INDEX idx_project_account_grants_project ON project_account_grants(project_id, status);

CREATE TABLE ai_account_setup_intents (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES ai_accounts(id) ON DELETE CASCADE,
  execution_workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  approved_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('setup', 'reauthenticate', 'clear')),
  status TEXT NOT NULL DEFAULT 'requested' CHECK (status IN ('requested', 'approved', 'rejected', 'completed', 'revoked')),
  requested_at TEXT NOT NULL,
  approved_at TEXT,
  completed_at TEXT
);
CREATE INDEX idx_ai_account_setup_intents_workspace
  ON ai_account_setup_intents(execution_workspace_id, status, requested_at);

-- Project-owned history and execution records. None derive authorization from
-- an execution Workspace membership or carry a collaborative Workspace FK.
CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  created_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  sender_type TEXT NOT NULL CHECK (sender_type IN ('user', 'conclave', 'worker', 'system')),
  sender_id TEXT NOT NULL,
  content TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('user', 'conclave', 'status', 'approval', 'artifact', 'system')),
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE TABLE goals (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  chat_id TEXT REFERENCES chats(id) ON DELETE SET NULL,
  created_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  original_message TEXT NOT NULL,
  objective TEXT NOT NULL,
  constraints_json TEXT NOT NULL DEFAULT '[]',
  completion_criteria_json TEXT NOT NULL DEFAULT '[]',
  verification_policy_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('draft', 'ready', 'running', 'waiting', 'completed', 'failed', 'cancelled', 'superseded')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
  workflow_instance_id TEXT,
  parent_run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  policy_snapshot_json TEXT NOT NULL,
  current_phase_id TEXT,
  status TEXT NOT NULL CHECK (status IN ('created', 'running', 'paused', 'completed', 'failed', 'cancelled')),
  started_at TEXT,
  finished_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE phases (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  purpose TEXT NOT NULL,
  sequence INTEGER NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed', 'failed', 'skipped')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (run_id, sequence)
);

CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  phase_id TEXT NOT NULL REFERENCES phases(id) ON DELETE CASCADE,
  objective TEXT NOT NULL,
  role TEXT NOT NULL,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  input_json TEXT NOT NULL DEFAULT '{}',
  output_contract_json TEXT NOT NULL DEFAULT '{}',
  execution_policy_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('pending', 'ready', 'running', 'completed', 'failed', 'blocked', 'cancelled')),
  requires_independent_verification INTEGER NOT NULL DEFAULT 0 CHECK (requires_independent_verification IN (0, 1)),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE task_dependencies (
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  depends_on_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

CREATE TABLE attempts (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  worker_id TEXT REFERENCES workers(id) ON DELETE SET NULL,
  attempt_number INTEGER NOT NULL,
  input_snapshot_json TEXT NOT NULL,
  output_artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  failure_class TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  UNIQUE (task_id, attempt_number)
);

CREATE TABLE worker_assignments (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  execution_workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  workspace_project_grant_id TEXT NOT NULL,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  runtime_identity_id TEXT NOT NULL REFERENCES workspace_runtime_identities(id) ON DELETE RESTRICT,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  worker_version TEXT NOT NULL,
  account_id TEXT NOT NULL REFERENCES ai_accounts(id) ON DELETE RESTRICT,
  model TEXT,
  config_json TEXT NOT NULL DEFAULT '{}',
  effective_permissions_json TEXT NOT NULL DEFAULT '[]',
  permission_snapshot_json TEXT NOT NULL,
  timeout_ms INTEGER NOT NULL DEFAULT 60000 CHECK (timeout_ms >= 1000),
  idempotency_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('created', 'dispatched', 'acknowledged', 'running', 'completed', 'failed', 'cancelled', 'timed_out')),
  input_json TEXT NOT NULL DEFAULT '{}',
  output_json TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (workspace_project_grant_id, project_id, execution_workspace_id)
    REFERENCES workspace_project_grants(id, project_id, workspace_id)
);
CREATE INDEX idx_worker_assignments_project ON worker_assignments(project_id, created_at);
CREATE INDEX idx_worker_assignments_workspace ON worker_assignments(execution_workspace_id, status);

CREATE TABLE completion_criteria (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  verification_requirement TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'verified', 'failed', 'waived')),
  evidence_artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  verified_by_worker_id TEXT REFERENCES workers(id) ON DELETE SET NULL,
  verification_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE artifacts (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  attempt_id TEXT REFERENCES attempts(id) ON DELETE SET NULL,
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  media_type TEXT NOT NULL,
  content_digest TEXT NOT NULL,
  storage_kind TEXT NOT NULL CHECK (storage_kind IN ('inline', 'r2')),
  storage_key TEXT,
  inline_content TEXT,
  size_bytes INTEGER NOT NULL,
  provenance_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE TABLE findings (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  attempt_id TEXT REFERENCES attempts(id) ON DELETE SET NULL,
  category TEXT NOT NULL,
  severity TEXT NOT NULL CHECK (severity IN ('blocker', 'critical', 'warning', 'info')),
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('open', 'resolved', 'ignored', 'waived')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE verifications (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  criterion_id TEXT REFERENCES completion_criteria(id) ON DELETE SET NULL,
  verifier_worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE RESTRICT,
  conclusion TEXT NOT NULL CHECK (conclusion IN ('verified', 'failed', 'inconclusive')),
  evidence_artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE events (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  UNIQUE (run_id, sequence)
);

CREATE TABLE usage (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  worker_id TEXT REFERENCES workers(id) ON DELETE SET NULL,
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  account_id TEXT REFERENCES ai_accounts(id) ON DELETE SET NULL,
  requester_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  provider TEXT,
  billing_category TEXT NOT NULL DEFAULT 'unknown' CHECK (billing_category IN ('subscription', 'api', 'local', 'unknown')),
  model TEXT,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_micros INTEGER,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  recorded_at TEXT NOT NULL
);

CREATE TABLE budgets (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE CASCADE,
  account_id TEXT REFERENCES ai_accounts(id) ON DELETE CASCADE,
  max_cost_micros INTEGER,
  max_input_tokens INTEGER,
  max_output_tokens INTEGER,
  used_input_tokens INTEGER NOT NULL DEFAULT 0,
  used_output_tokens INTEGER NOT NULL DEFAULT 0,
  used_cost_micros INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'exhausted', 'disabled')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE project_audit_log (
  id TEXT PRIMARY KEY,
  project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'workspace_runtime', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE TABLE human_approvals (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  decided_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  prompt TEXT NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('pending', 'approved', 'rejected')),
  requested_at TEXT NOT NULL,
  decided_at TEXT
);

CREATE INDEX idx_chats_project ON chats(project_id);
CREATE INDEX idx_goals_project ON goals(project_id, status);
CREATE INDEX idx_runs_project ON runs(project_id, status);
CREATE INDEX idx_artifacts_project ON artifacts(project_id, run_id);
CREATE INDEX idx_findings_project ON findings(project_id, run_id);
CREATE INDEX idx_verifications_project ON verifications(project_id, run_id);
CREATE INDEX idx_events_run_seq ON events(run_id, sequence);
CREATE INDEX idx_usage_project ON usage(project_id, run_id);
CREATE INDEX idx_project_audit_log_project ON project_audit_log(project_id, created_at);
