-- Conclave AX Architecture v4 clean D1 baseline.
-- This is the complete development schema, not a compatibility migration.
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

-- Better Auth account model. Provider identities are authentication records,
-- not Conclave authorization records.
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

-- Better Auth session model. The token is managed by Better Auth and is not a
-- Conclave authorization grant; Workspace and resource authorization remains
-- in Conclave tables and services.
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
CREATE INDEX idx_auth_verifications_identifier
  ON auth_verifications(identifier);

-- Better Auth passkey plugin model. Private keys remain on the authenticator;
-- Conclave stores only the public credential and its WebAuthn counter.
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

-- A passkey ceremony creates a short-lived, session-bound step-up proof.
-- Events are consumed by the application boundary and never become a general
-- authorization grant.
CREATE TABLE auth_step_up_events (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  method TEXT NOT NULL CHECK (method IN ('passkey', 'totp')),
  created_at TEXT NOT NULL,
  consumed_at TEXT
);
CREATE INDEX idx_auth_step_up_events_user
  ON auth_step_up_events(user_id, created_at);

CREATE TABLE auth_step_up_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  session_id TEXT NOT NULL,
  method TEXT NOT NULL CHECK (method IN ('passkey', 'totp')),
  authenticated_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE UNIQUE INDEX idx_auth_step_up_sessions_session
  ON auth_step_up_sessions(session_id);

CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'archived')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- Authentication events are intentionally separate from workspace audit_log:
-- sign-in and provider failures can happen before a workspace is selected.
-- details_json is an allow-listed metadata object; it must never contain
-- cookies, OAuth tokens, passkey material, or raw provider credentials.
CREATE TABLE auth_audit_events (
  id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  session_id TEXT,
  workspace_id TEXT REFERENCES workspaces(id) ON DELETE SET NULL,
  action TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'denied')),
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX idx_auth_audit_events_user
  ON auth_audit_events(user_id, created_at);
CREATE INDEX idx_auth_audit_events_action
  ON auth_audit_events(action, created_at);

CREATE TABLE workspace_memberships (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'removed')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id, user_id)
);
CREATE INDEX idx_workspace_memberships_user ON workspace_memberships(user_id);

CREATE TABLE workspace_invitations (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('admin', 'member', 'viewer')),
  token_hash TEXT NOT NULL UNIQUE,
  invited_by_user_id TEXT NOT NULL REFERENCES users(id),
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'expired', 'revoked')),
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id),
  accepted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_workspace_invitations_workspace ON workspace_invitations(workspace_id, status);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  repository_id TEXT,
  settings_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, workspace_id)
);
CREATE INDEX idx_projects_workspace ON projects(workspace_id);

CREATE TABLE project_execution_preferences (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL UNIQUE REFERENCES projects(id) ON DELETE CASCADE,
  preferred_worker_ids_json TEXT NOT NULL DEFAULT '[]',
  preferred_model_ids_json TEXT NOT NULL DEFAULT '[]',
  preferred_credential_profile_ids_json TEXT NOT NULL DEFAULT '[]',
  quality TEXT NOT NULL DEFAULT 'balanced' CHECK (quality IN ('fast', 'balanced', 'high')),
  budget_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE user_execution_preferences (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  preferred_private_credential_profile_id TEXT,
  execution_preference TEXT NOT NULL DEFAULT 'auto' CHECK (execution_preference IN ('auto', 'subscription', 'api')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id, user_id)
);
CREATE INDEX idx_user_execution_preferences_user ON user_execution_preferences(user_id, workspace_id);

CREATE TABLE project_memberships (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('lead', 'collaborator', 'viewer')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, user_id)
);

CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  created_by_user_id TEXT NOT NULL REFERENCES users(id),
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_chats_project ON chats(project_id);

CREATE TABLE goals (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  chat_id TEXT REFERENCES chats(id) ON DELETE SET NULL,
  created_by_user_id TEXT REFERENCES users(id),
  original_message TEXT NOT NULL,
  objective TEXT NOT NULL,
  constraints_json TEXT NOT NULL DEFAULT '[]',
  completion_criteria_json TEXT NOT NULL DEFAULT '[]',
  verification_policy_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('draft', 'ready', 'running', 'waiting', 'completed', 'failed', 'cancelled', 'superseded')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_goals_workspace ON goals(workspace_id);
CREATE INDEX idx_goals_project ON goals(project_id);

CREATE TABLE chat_messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  sender_type TEXT NOT NULL CHECK (sender_type IN ('user', 'conclave', 'worker', 'system')),
  sender_id TEXT NOT NULL,
  content TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('user', 'conclave', 'status', 'approval', 'artifact', 'system')),
  goal_id TEXT REFERENCES goals(id) ON DELETE SET NULL,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);
CREATE INDEX idx_chat_messages_chat ON chat_messages(chat_id, created_at);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
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
CREATE INDEX idx_runs_goal ON runs(goal_id);
CREATE INDEX idx_runs_workspace ON runs(workspace_id);

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

CREATE TABLE hosts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  hostname TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('enrolled', 'online', 'offline', 'draining', 'revoked')),
  version TEXT NOT NULL,
  capabilities_json TEXT NOT NULL DEFAULT '{}',
  auth_token_hash TEXT UNIQUE,
  enrolled_at TEXT NOT NULL,
  last_heartbeat_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE host_workspace_bindings (
  id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked')),
  granted_by_user_id TEXT REFERENCES users(id),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (host_id, workspace_id)
);
CREATE INDEX idx_host_workspace_bindings_workspace ON host_workspace_bindings(workspace_id, status);

CREATE TABLE host_enrollments (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  created_by_user_id TEXT NOT NULL REFERENCES users(id),
  expires_at TEXT NOT NULL,
  used_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE host_sessions (
  id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  client_version TEXT NOT NULL,
  protocol_version TEXT NOT NULL,
  ip_address TEXT,
  connected_at TEXT NOT NULL,
  last_heartbeat_at TEXT NOT NULL,
  disconnected_at TEXT
);
CREATE INDEX idx_host_sessions_host ON host_sessions(host_id);

CREATE TABLE host_releases (
  version TEXT PRIMARY KEY,
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta', 'development')),
  min_supported_host_version TEXT,
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
  min_host_version TEXT NOT NULL,
  supported_os_json TEXT NOT NULL,
  supported_arch_json TEXT NOT NULL,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  permissions_json TEXT NOT NULL DEFAULT '[]',
  credential_requirements_json TEXT NOT NULL DEFAULT '[]',
  config_schema_json TEXT NOT NULL DEFAULT '{}',
  session_modes_json TEXT NOT NULL DEFAULT '["stateless"]',
  concurrency_model_json TEXT NOT NULL DEFAULT '{}',
  entrypoint TEXT NOT NULL,
  package_digest TEXT NOT NULL,
  package_r2_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (worker_id, version)
  ,UNIQUE (id, worker_id)
);
CREATE INDEX idx_worker_versions_channel ON worker_versions(worker_id, channel, is_revoked);

CREATE TABLE host_worker_installations (
  id TEXT PRIMARY KEY,
  host_id TEXT NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  worker_version_id TEXT NOT NULL REFERENCES worker_versions(id),
  status TEXT NOT NULL CHECK (status IN (
    'absent', 'requested', 'downloading', 'verifying', 'installing',
    'ready', 'updating', 'degraded', 'failed', 'removing'
  )),
  error TEXT,
  installed_at TEXT,
  updated_at TEXT NOT NULL,
  UNIQUE (host_id, worker_id, worker_version_id)
);
CREATE INDEX idx_host_worker_installations_host ON host_worker_installations(host_id, status);

CREATE TABLE credential_profiles (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  owner_type TEXT NOT NULL CHECK (owner_type IN ('user', 'workspace')),
  owner_id TEXT NOT NULL,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  host_id TEXT REFERENCES hosts(id) ON DELETE SET NULL,
  display_name TEXT NOT NULL,
  auth_type TEXT NOT NULL CHECK (auth_type IN ('none', 'api_key', 'oauth_browser', 'local_cli_session', 'interactive_custom')),
  secret_location TEXT NOT NULL CHECK (secret_location IN ('none', 'host_secure_store')),
  secret_reference TEXT,
  status TEXT NOT NULL CHECK (status IN ('setup_required', 'authenticating', 'ready', 'expired', 'error', 'revoked')),
  sharing_policy TEXT NOT NULL CHECK (sharing_policy IN ('private_only', 'owner_controlled', 'workspace_capable')),
  provider_metadata_json TEXT NOT NULL DEFAULT '{}',
  concurrency_limit INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  CHECK ((owner_type = 'workspace' AND owner_id = workspace_id) OR owner_type = 'user'),
  CHECK ((secret_location = 'host_secure_store' AND host_id IS NOT NULL) OR secret_location <> 'host_secure_store'),
  UNIQUE (id, workspace_id),
  FOREIGN KEY (host_id, workspace_id) REFERENCES host_workspace_bindings(host_id, workspace_id)
);
CREATE INDEX idx_credential_profiles_workspace ON credential_profiles(workspace_id, status);
CREATE INDEX idx_credential_profiles_owner ON credential_profiles(owner_type, owner_id);

CREATE TABLE credential_grants (
  id TEXT PRIMARY KEY,
  credential_profile_id TEXT NOT NULL REFERENCES credential_profiles(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  grantee_type TEXT NOT NULL CHECK (grantee_type IN ('user', 'workspace', 'role')),
  grantee_id TEXT NOT NULL,
  use_permission INTEGER NOT NULL DEFAULT 1 CHECK (use_permission IN (0, 1)),
  granted_by_user_id TEXT NOT NULL REFERENCES users(id),
  created_at TEXT NOT NULL,
  expires_at TEXT,
  usage_limit INTEGER CHECK (usage_limit IS NULL OR usage_limit >= 0),
  revoked_at TEXT,
  UNIQUE (credential_profile_id, grantee_type, grantee_id),
  FOREIGN KEY (credential_profile_id, workspace_id) REFERENCES credential_profiles(id, workspace_id)
);
CREATE INDEX idx_credential_grants_grantee ON credential_grants(workspace_id, grantee_type, grantee_id);

CREATE TABLE attempts (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  worker_id TEXT REFERENCES workers(id),
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
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id),
  host_id TEXT NOT NULL REFERENCES hosts(id),
  worker_id TEXT NOT NULL REFERENCES workers(id),
  resolved_worker_version TEXT NOT NULL,
  credential_profile_id TEXT NOT NULL REFERENCES credential_profiles(id),
  model TEXT,
  config_json TEXT NOT NULL DEFAULT '{}',
  session_policy TEXT NOT NULL CHECK (session_policy IN ('stateless', 'isolated_workspace', 'reuse_session', 'persistent_context')),
  permissions_json TEXT NOT NULL DEFAULT '[]',
  context_refs_json TEXT NOT NULL DEFAULT '[]',
  timeout_ms INTEGER NOT NULL DEFAULT 60000 CHECK (timeout_ms >= 1000),
  idempotency_key TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('created', 'dispatched', 'acknowledged', 'running', 'completed', 'failed', 'cancelled', 'timed_out')),
  input_json TEXT NOT NULL DEFAULT '{}',
  output_json TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (host_id, workspace_id) REFERENCES host_workspace_bindings(host_id, workspace_id),
  FOREIGN KEY (credential_profile_id, workspace_id) REFERENCES credential_profiles(id, workspace_id)
);
CREATE INDEX idx_worker_assignments_workspace ON worker_assignments(workspace_id, created_at);
CREATE INDEX idx_worker_assignments_host ON worker_assignments(host_id, status);
CREATE INDEX idx_worker_assignments_run ON worker_assignments(run_id);

CREATE TABLE completion_criteria (
  id TEXT PRIMARY KEY,
  goal_id TEXT NOT NULL REFERENCES goals(id) ON DELETE CASCADE,
  description TEXT NOT NULL,
  verification_requirement TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'verified', 'failed', 'waived')),
  evidence_artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  verified_by_worker_id TEXT REFERENCES workers(id),
  verification_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE artifacts (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
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
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
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
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  criterion_id TEXT REFERENCES completion_criteria(id) ON DELETE SET NULL,
  verifier_worker_id TEXT NOT NULL REFERENCES workers(id),
  conclusion TEXT NOT NULL CHECK (conclusion IN ('verified', 'failed', 'inconclusive')),
  evidence_artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  notes TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE events (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
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

CREATE TABLE budgets (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE CASCADE,
  credential_profile_id TEXT REFERENCES credential_profiles(id) ON DELETE CASCADE,
  max_cost_micros INTEGER,
  max_input_tokens INTEGER,
  max_output_tokens INTEGER,
  used_input_tokens INTEGER NOT NULL DEFAULT 0,
  used_output_tokens INTEGER NOT NULL DEFAULT 0,
  used_cost_micros INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'exhausted', 'disabled')),
  max_attempts INTEGER,
  max_wall_time_seconds INTEGER,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE usage (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  credential_profile_id TEXT REFERENCES credential_profiles(id) ON DELETE SET NULL,
  credential_profile_owner_type TEXT CHECK (credential_profile_owner_type IN ('user', 'workspace')),
  credential_profile_owner_id TEXT,
  requester_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  host_id TEXT REFERENCES hosts(id) ON DELETE SET NULL,
  provider TEXT,
  billing_category TEXT NOT NULL DEFAULT 'unknown' CHECK (billing_category IN ('subscription', 'api', 'local', 'unknown')),
  model TEXT,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_micros INTEGER,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  recorded_at TEXT NOT NULL
);

CREATE TABLE model_calls (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  model TEXT NOT NULL,
  request_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  response_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at TEXT NOT NULL,
  finished_at TEXT
);

CREATE TABLE audit_log (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'host', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  ip_address TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE ci_evidence (
  evidence_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  repository_id TEXT,
  external_run_id TEXT NOT NULL,
  revision TEXT NOT NULL,
  workflow TEXT NOT NULL,
  source TEXT NOT NULL,
  conclusion TEXT NOT NULL CHECK (conclusion IN ('success', 'failure', 'cancelled', 'neutral')),
  checks_json TEXT NOT NULL DEFAULT '[]',
  smoke_tests_json TEXT NOT NULL DEFAULT '[]',
  health_checks_json TEXT NOT NULL DEFAULT '[]',
  raw_payload_json TEXT,
  observed_at TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'available',
  claimed_at TEXT,
  consumed_at TEXT,
  UNIQUE (run_id, repository_id, revision, workflow, external_run_id)
);

CREATE TABLE retention_policies (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  audit_days INTEGER NOT NULL,
  artifact_days INTEGER NOT NULL,
  usage_days INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id)
);

CREATE TABLE human_approvals (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id),
  decided_by_user_id TEXT REFERENCES users(id),
  prompt TEXT NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('pending', 'approved', 'rejected')),
  requested_at TEXT NOT NULL,
  decided_at TEXT
);

CREATE INDEX idx_goals_workspace_status ON goals(workspace_id, status);
CREATE INDEX idx_runs_workspace_status ON runs(workspace_id, status);
CREATE INDEX idx_tasks_status ON tasks(status);
CREATE INDEX idx_artifacts_run ON artifacts(run_id);
CREATE INDEX idx_findings_run ON findings(run_id);
CREATE INDEX idx_verifications_run ON verifications(run_id);
CREATE INDEX idx_events_run_seq ON events(run_id, sequence);
CREATE INDEX idx_usage_run ON usage(run_id);
CREATE INDEX idx_audit_log_workspace ON audit_log(workspace_id, created_at);
