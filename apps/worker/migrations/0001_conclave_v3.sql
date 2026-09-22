-- =========================================================================
-- Conclave AX Architecture v3 - Clean D1 Database Schema Baseline
-- =========================================================================
PRAGMA foreign_keys = ON;

-- -------------------------------------------------------------------------
-- 1. Identity, Users & Auth Sessions
-- -------------------------------------------------------------------------
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT UNIQUE NOT NULL,
  display_name TEXT NOT NULL,
  avatar_url TEXT,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE auth_identities (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  subject TEXT NOT NULL,
  email TEXT,
  metadata_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (provider, subject),
  UNIQUE (user_id, provider)
);
CREATE INDEX idx_auth_identities_user ON auth_identities(user_id);

CREATE TABLE auth_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT UNIQUE NOT NULL,
  client_type TEXT NOT NULL CHECK (client_type IN ('web', 'desktop', 'cli', 'api')),
  ip_address TEXT,
  user_agent TEXT,
  expires_at TEXT NOT NULL,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_auth_sessions_user ON auth_sessions(user_id);
CREATE INDEX idx_auth_sessions_token ON auth_sessions(token_hash);

-- -------------------------------------------------------------------------
-- 2. Multi-User Hierarchy: Workspaces, Projects & Memberships
-- -------------------------------------------------------------------------
CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  slug TEXT UNIQUE NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'archived')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE workspace_memberships (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member', 'viewer')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (workspace_id, user_id)
);
CREATE INDEX idx_workspace_memberships_user ON workspace_memberships(user_id);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  description TEXT,
  repository_id TEXT,
  settings_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_projects_workspace ON projects(workspace_id);

CREATE TABLE project_memberships (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('lead', 'collaborator', 'viewer')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (project_id, user_id)
);

-- -------------------------------------------------------------------------
-- 3. AI Chats & Chat Messages
-- -------------------------------------------------------------------------
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

-- -------------------------------------------------------------------------
-- 4. Goals, Runs, Phases, Tasks & Attempts
-- -------------------------------------------------------------------------
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
  sender_type TEXT NOT NULL CHECK (sender_type IN ('user', 'conclave', 'agent', 'worker', 'system')),
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
CREATE INDEX idx_runs_workflow_instance ON runs(workflow_instance_id);

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
CREATE INDEX idx_phases_run ON phases(run_id);

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
CREATE INDEX idx_tasks_phase ON tasks(phase_id);

CREATE TABLE task_dependencies (
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  depends_on_task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

-- -------------------------------------------------------------------------
-- 5. Agents, Plugins & Workers (Fleet)
-- -------------------------------------------------------------------------
CREATE TABLE agents (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  hostname TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('enrolled', 'online', 'offline', 'busy', 'draining', 'revoked')),
  version TEXT NOT NULL,
  capabilities_json TEXT NOT NULL DEFAULT '{}',
  auth_token_hash TEXT,
  enrolled_at TEXT NOT NULL,
  last_heartbeat_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_agents_workspace ON agents(workspace_id);

CREATE TABLE agent_enrollments (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  token_hash TEXT UNIQUE NOT NULL,
  created_by_user_id TEXT NOT NULL REFERENCES users(id),
  expires_at TEXT NOT NULL,
  used_at TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL
);

CREATE TABLE agent_sessions (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  client_version TEXT NOT NULL,
  protocol_version TEXT NOT NULL,
  ip_address TEXT,
  connected_at TEXT NOT NULL,
  last_heartbeat_at TEXT NOT NULL,
  disconnected_at TEXT
);
CREATE INDEX idx_agent_sessions_agent ON agent_sessions(agent_id);

CREATE TABLE agent_releases (
  version TEXT PRIMARY KEY,
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta', 'development')),
  min_supported_agent_version TEXT,
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
CREATE INDEX idx_agent_releases_channel ON agent_releases(channel, is_revoked);

CREATE TABLE worker_plugins (
  id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL,
  description TEXT NOT NULL,
  publisher TEXT NOT NULL,
  supported_roles_json TEXT NOT NULL DEFAULT '[]',
  supported_capabilities_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK (status IN ('active', 'deprecated', 'revoked')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE worker_plugin_versions (
  id TEXT PRIMARY KEY,
  plugin_id TEXT NOT NULL REFERENCES worker_plugins(id) ON DELETE CASCADE,
  version TEXT NOT NULL,
  channel TEXT NOT NULL DEFAULT 'stable' CHECK (channel IN ('stable', 'beta', 'development')),
  protocol_version TEXT NOT NULL,
  min_agent_version TEXT NOT NULL,
  max_agent_version TEXT,
  supported_os_json TEXT NOT NULL,
  supported_arch_json TEXT NOT NULL,
  package_digest TEXT NOT NULL,
  package_r2_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  permissions_json TEXT NOT NULL DEFAULT '[]',
  billing_modes_json TEXT NOT NULL DEFAULT '[]',
  config_schema_json TEXT DEFAULT '{}',
  secret_schema_json TEXT DEFAULT '{}',
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL,
  UNIQUE (plugin_id, version)
);
CREATE INDEX idx_worker_plugin_versions_channel ON worker_plugin_versions(plugin_id, channel, is_revoked);

CREATE TABLE agent_plugin_installs (
  id TEXT PRIMARY KEY,
  agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  plugin_id TEXT NOT NULL REFERENCES worker_plugins(id) ON DELETE CASCADE,
  installed_version TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('installing', 'installed', 'active', 'error', 'removed')),
  error TEXT,
  installed_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (agent_id, plugin_id, installed_version)
);

CREATE TABLE workers (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  plugin_id TEXT NOT NULL REFERENCES worker_plugins(id) ON DELETE CASCADE,
  plugin_version_policy TEXT NOT NULL DEFAULT 'latest',
  name TEXT NOT NULL,
  roles_json TEXT NOT NULL DEFAULT '[]',
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  config_json TEXT NOT NULL DEFAULT '{}',
  secret_refs_json TEXT NOT NULL DEFAULT '[]',
  billing_mode TEXT NOT NULL CHECK (billing_mode IN ('api_metered', 'subscription', 'local_compute', 'external', 'manual', 'free')),
  cost_metadata_json TEXT DEFAULT '{}',
  independence_key TEXT NOT NULL,
  concurrency_limit INTEGER NOT NULL DEFAULT 1,
  session_policy TEXT NOT NULL DEFAULT 'stateless' CHECK (session_policy IN ('stateless', 'isolated_workspace', 'reuse_session', 'persistent_context')),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
  status TEXT NOT NULL CHECK (status IN ('available', 'busy', 'disabled', 'offline', 'draining', 'error')) DEFAULT 'available',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_workers_workspace ON workers(workspace_id);
CREATE INDEX idx_workers_agent ON workers(agent_id);

CREATE TABLE attempts (
  id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  attempt_number INTEGER NOT NULL,
  input_snapshot_json TEXT NOT NULL,
  output_artifact_ids_json TEXT NOT NULL DEFAULT '[]',
  status TEXT NOT NULL CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  failure_class TEXT,
  started_at TEXT NOT NULL,
  finished_at TEXT,
  UNIQUE (task_id, attempt_number)
);
CREATE INDEX idx_attempts_task ON attempts(task_id);

CREATE TABLE worker_assignments (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  agent_id TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id) ON DELETE CASCADE,
  plugin_id TEXT NOT NULL REFERENCES worker_plugins(id),
  resolved_plugin_version TEXT,
  status TEXT NOT NULL CHECK (status IN ('created', 'dispatched', 'acknowledged', 'running', 'completed', 'failed', 'cancelled', 'timed_out')),
  input_json TEXT NOT NULL,
  idempotency_key TEXT UNIQUE NOT NULL,
  timeout_ms INTEGER NOT NULL DEFAULT 60000,
  output_json TEXT,
  error_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_worker_assignments_run ON worker_assignments(run_id);
CREATE INDEX idx_worker_assignments_agent ON worker_assignments(agent_id);

-- -------------------------------------------------------------------------
-- 6. Completion Criteria & Verifications
-- -------------------------------------------------------------------------
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
CREATE INDEX idx_completion_criteria_goal ON completion_criteria(goal_id);

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
CREATE INDEX idx_verifications_run ON verifications(run_id);

-- -------------------------------------------------------------------------
-- 7. Artifacts, Findings & Events
-- -------------------------------------------------------------------------
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
CREATE INDEX idx_artifacts_run ON artifacts(run_id);

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
CREATE INDEX idx_findings_run ON findings(run_id);

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
CREATE INDEX idx_events_run_seq ON events(run_id, sequence);

-- -------------------------------------------------------------------------
-- 8. Budgets & Usage Accounting
-- -------------------------------------------------------------------------
CREATE TABLE budgets (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE CASCADE,
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
CREATE INDEX idx_budgets_run ON budgets(run_id);

CREATE TABLE usage (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  cost_micros INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  recorded_at TEXT NOT NULL
);
CREATE INDEX idx_usage_run ON usage(run_id);

-- -------------------------------------------------------------------------
-- 9. Audit Log & CI Evidence
-- -------------------------------------------------------------------------
CREATE TABLE audit_log (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'agent', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  ip_address TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_audit_log_workspace ON audit_log(workspace_id);

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
CREATE INDEX idx_ci_evidence_run ON ci_evidence(run_id);

CREATE INDEX idx_ci_evidence_claims ON ci_evidence(run_id, status, observed_at);

-- -------------------------------------------------------------------------
-- 10. Collaboration, extensions, security and durable execution
-- -------------------------------------------------------------------------
ALTER TABLE workspace_memberships ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
CREATE INDEX idx_workspace_memberships_status
  ON workspace_memberships(workspace_id, status);

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
CREATE INDEX idx_workspace_invitations_email ON workspace_invitations(email, status);
CREATE INDEX idx_workspace_invitations_project ON workspace_invitations(project_id, status);

CREATE TABLE model_calls (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  attempt_id TEXT NOT NULL REFERENCES attempts(id) ON DELETE CASCADE,
  worker_id TEXT NOT NULL REFERENCES workers(id),
  connection_id TEXT NOT NULL,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  request_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  response_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  status TEXT NOT NULL,
  input_tokens INTEGER,
  output_tokens INTEGER,
  started_at TEXT NOT NULL,
  finished_at TEXT
);
CREATE INDEX idx_model_calls_attempt ON model_calls(attempt_id, started_at);
CREATE INDEX idx_model_calls_workspace ON model_calls(workspace_id, started_at);

CREATE TABLE extensions (
  row_id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  extension_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('provider', 'agent', 'tool', 'ci', 'human')),
  name TEXT NOT NULL,
  version TEXT NOT NULL,
  manifest_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('active', 'disabled', 'pending_review')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id, extension_id, version)
);
CREATE INDEX idx_extensions_organization ON extensions(organization_id);

CREATE TABLE workflow_templates (
  row_id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  template_id TEXT NOT NULL,
  name TEXT NOT NULL,
  version INTEGER NOT NULL,
  template_json TEXT NOT NULL DEFAULT '{}',
  status TEXT NOT NULL CHECK (status IN ('draft', 'active', 'archived')),
  created_by_user_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id, template_id, version)
);
CREATE INDEX idx_workflow_templates_organization ON workflow_templates(organization_id);

CREATE TABLE credentials (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider TEXT NOT NULL,
  key_id TEXT NOT NULL,
  algorithm TEXT NOT NULL CHECK (algorithm = 'AES-GCM'),
  iv TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  created_at TEXT NOT NULL,
  expires_at TEXT,
  UNIQUE (organization_id, provider)
);
CREATE INDEX idx_credentials_organization ON credentials(organization_id);

CREATE TABLE retention_policies (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  audit_days INTEGER NOT NULL,
  artifact_days INTEGER NOT NULL,
  usage_days INTEGER NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (organization_id)
);

CREATE TABLE human_approvals (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  task_id TEXT REFERENCES tasks(id) ON DELETE SET NULL,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id),
  decided_by_user_id TEXT REFERENCES users(id),
  prompt TEXT NOT NULL,
  decision TEXT NOT NULL CHECK (decision IN ('pending', 'approved', 'rejected')),
  requested_at TEXT NOT NULL,
  decided_at TEXT
);
CREATE INDEX idx_human_approvals_organization ON human_approvals(organization_id);
CREATE INDEX idx_human_approvals_run ON human_approvals(run_id);

CREATE TABLE forge_executions (
  execution_id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  workspace_id TEXT,
  status TEXT NOT NULL CHECK (status IN ('started', 'completed', 'failed', 'cancelled', 'needs_input')),
  result_artifact_id TEXT,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_forge_executions_run ON forge_executions(run_id);
CREATE UNIQUE INDEX idx_forge_executions_run_unique ON forge_executions(run_id);

CREATE TABLE run_external_executions (
  id TEXT PRIMARY KEY,
  run_id TEXT NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  execution_kind TEXT NOT NULL,
  external_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (run_id, execution_kind),
  UNIQUE (execution_kind, external_id)
);
CREATE INDEX idx_run_external_executions_run ON run_external_executions(run_id);
