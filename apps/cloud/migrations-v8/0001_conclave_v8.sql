CREATE TABLE users (
  id TEXT PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'deactivated')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  avatar_url TEXT,
  email_verified INTEGER NOT NULL DEFAULT 0 CHECK (email_verified IN (0, 1))
);

CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  description TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  settings_json TEXT NOT NULL DEFAULT '{}'
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

CREATE TABLE execution_workspaces (
  id TEXT PRIMARY KEY,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  name TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'offline' CHECK (
    status IN ('online', 'offline', 'busy', 'draining', 'revoked')
  ),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (id, owner_user_id)
);

CREATE INDEX idx_workspaces_owner ON execution_workspaces(owner_user_id);

CREATE TABLE workspace_runtime_identities (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  credential_token_hash TEXT NOT NULL,
  installation_id TEXT,
  created_at TEXT NOT NULL,
  revoked_at TEXT,
  CHECK (installation_id IS NOT NULL OR revoked_at IS NOT NULL)
);

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

CREATE INDEX idx_workstreams_project ON workstreams(project_id, status);

CREATE TABLE discussion_messages (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  author_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  body TEXT NOT NULL,
  references_json TEXT NOT NULL DEFAULT '[]',
  edited_at TEXT,
  created_at TEXT NOT NULL
);

CREATE INDEX idx_discussion_messages_workstream ON discussion_messages(workstream_id, created_at);

CREATE TABLE workstream_execution_policies (
  workstream_id TEXT PRIMARY KEY REFERENCES workstreams(id) ON DELETE CASCADE,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  primary_workspace_id TEXT REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  allowed_worker_type_ids_json TEXT NOT NULL DEFAULT '[]',
  allowed_models_json TEXT NOT NULL DEFAULT '[]'
);

CREATE TABLE runs (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  status TEXT NOT NULL CHECK (
    status IN ('created', 'running', 'paused', 'completed', 'failed', 'cancelled')
  ),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  started_at TEXT,
  finished_at TEXT,
  workflow_instance_id TEXT,
  policy_snapshot_json TEXT NOT NULL DEFAULT '{}'
);

CREATE TABLE worker_assignments (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  execution_workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  runtime_identity_id TEXT NOT NULL REFERENCES workspace_runtime_identities(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  status TEXT NOT NULL,
  input_json TEXT NOT NULL DEFAULT '{}',
  output_json TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  workspace_project_grant_id TEXT REFERENCES workspace_project_grants(id) ON DELETE SET NULL,
  error_json TEXT,
  requested_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  workspace_worker_id TEXT,
  task_id TEXT,
  attempt_id TEXT,
  engine_version TEXT,
  model TEXT,
  config_json TEXT NOT NULL DEFAULT '{}',
  effective_permissions_json TEXT NOT NULL DEFAULT '[]',
  permission_snapshot_json TEXT NOT NULL DEFAULT '{}',
  timeout_ms INTEGER,
  idempotency_key TEXT,
  session_policy TEXT NOT NULL DEFAULT 'stateless' CHECK (
    session_policy IN ('stateless', 'durable_session')
  )
);

CREATE TABLE artifacts (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  run_id TEXT REFERENCES runs(id) ON DELETE SET NULL,
  workstream_id TEXT REFERENCES workstreams(id) ON DELETE SET NULL,
  work_request_id TEXT REFERENCES work_requests(id) ON DELETE SET NULL,
  assignment_id TEXT REFERENCES worker_assignments(id) ON DELETE SET NULL,
  content_digest TEXT NOT NULL,
  storage_key TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE INDEX idx_runs_workstream ON runs(workstream_id, created_at);

CREATE INDEX idx_assignments_work_request ON worker_assignments(work_request_id, created_at);

CREATE INDEX idx_artifacts_work_request ON artifacts(work_request_id, created_at);

CREATE TABLE workspace_project_grants (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL,
  granted_by_user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK (
    status IN ('active', 'suspended', 'revoked', 'expired')
  ),
  allowed_worker_ids_json TEXT NOT NULL DEFAULT '[]',
  allowed_permissions_json TEXT NOT NULL DEFAULT '[]',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  expires_at TEXT,
  allowed_worker_capabilities_json TEXT NOT NULL DEFAULT '[]',
  network_policy_json TEXT NOT NULL DEFAULT '{"mode":"deny_all","allowedHosts":[]}',
  concurrency_json TEXT NOT NULL DEFAULT '{"maxConcurrentAssignments":1}',
  UNIQUE (id, project_id, workspace_id),
  FOREIGN KEY (workspace_id, granted_by_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

CREATE INDEX idx_workspace_project_grants_project
  ON workspace_project_grants(project_id, status);

CREATE TRIGGER workspace_project_grant_status_transition_valid
BEFORE UPDATE OF status ON workspace_project_grants
WHEN OLD.status IS NOT NEW.status AND NOT (
  (OLD.status = 'active' AND NEW.status IN ('suspended', 'revoked', 'expired')) OR
  (OLD.status = 'suspended' AND NEW.status IN ('active', 'revoked', 'expired'))
)
BEGIN
  SELECT RAISE(ABORT, 'invalid Workspace Project Grant status transition');
END;

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

CREATE TABLE workspace_audit_log (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('user', 'workspace', 'worker', 'system')),
  actor_id TEXT NOT NULL,
  action TEXT NOT NULL,
  target_type TEXT NOT NULL,
  target_id TEXT NOT NULL,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL
);

CREATE INDEX idx_workspace_audit_time
  ON workspace_audit_log(workspace_id, created_at DESC);

CREATE TABLE project_invitations (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  email TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('collaborator', 'viewer')),
  token_hash TEXT NOT NULL UNIQUE,
  invited_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (
    status IN ('pending', 'accepted', 'expired', 'revoked')
  ),
  expires_at TEXT NOT NULL,
  accepted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  accepted_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_project_invitations_project ON project_invitations(project_id, status);

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

CREATE INDEX idx_project_audit_log_project ON project_audit_log(project_id, created_at);

CREATE INDEX idx_worker_assignments_requester
  ON worker_assignments(requested_by_user_id, created_at);

CREATE TABLE workspace_runtime_facts (
  workspace_id TEXT PRIMARY KEY REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  platform TEXT,
  architecture TEXT,
  hostname TEXT,
  app_version TEXT,
  runtime_capabilities_json TEXT NOT NULL DEFAULT '[]',
  updated_at TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_workspace_runtime_token_hash
  ON workspace_runtime_identities(credential_token_hash);

CREATE INDEX idx_workspace_runtime_active
  ON workspace_runtime_identities(workspace_id, revoked_at);

CREATE INDEX idx_assignments_workspace_worker
  ON worker_assignments(workspace_worker_id, status);

CREATE TABLE workspace_releases (
  version TEXT PRIMARY KEY,
  channel TEXT NOT NULL DEFAULT 'stable'
    CHECK (channel IN ('stable', 'beta', 'development')),
  min_supported_workspace_version TEXT,
  supported_os_json TEXT NOT NULL DEFAULT '["macos","linux","windows"]',
  supported_arch_json TEXT NOT NULL DEFAULT '["arm64","x64"]',
  package_digest TEXT NOT NULL,
  package_r2_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  release_notes TEXT,
  is_revoked INTEGER NOT NULL DEFAULT 0 CHECK (is_revoked IN (0, 1)),
  revoked_at TEXT,
  revocation_reason TEXT,
  created_at TEXT NOT NULL,
  signing_key_id TEXT
);

CREATE TABLE release_signing_key_revocations (
  key_id TEXT PRIMARY KEY,
  revoked_at TEXT NOT NULL,
  revoked_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  reason TEXT NOT NULL
);

CREATE UNIQUE INDEX idx_runtime_installation_active
  ON workspace_runtime_identities(installation_id)
  WHERE revoked_at IS NULL;

CREATE TABLE workspace_sessions (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL
    REFERENCES execution_workspaces(id)
    ON DELETE CASCADE,
  runtime_identity_id TEXT NOT NULL
    REFERENCES workspace_runtime_identities(id)
    ON DELETE CASCADE,
  client_version TEXT NOT NULL,
  protocol_version TEXT NOT NULL,
  ip_address TEXT,
  connected_at TEXT NOT NULL,
  last_heartbeat_at TEXT NOT NULL,
  disconnected_at TEXT
);

CREATE INDEX idx_workspace_sessions_workspace
  ON workspace_sessions(workspace_id);

CREATE TABLE desktop_auth_intents (
  id TEXT PRIMARY KEY,
  poll_token_hash TEXT NOT NULL,
  client_name TEXT NOT NULL,
  audience TEXT NOT NULL DEFAULT 'conclave.desktop.management' CHECK (audience IN ('conclave.desktop.management', 'conclave.profile-lab.management')),
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  approved_at TEXT,
  approved_user_id TEXT REFERENCES users(id) ON DELETE CASCADE,
  claimed_at TEXT,
  claimed_session_id TEXT,
  denied_at TEXT
);

CREATE INDEX idx_desktop_auth_intents_expiry
  ON desktop_auth_intents(expires_at)
  WHERE claimed_at IS NULL AND denied_at IS NULL;

CREATE TABLE desktop_human_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  audience TEXT NOT NULL CHECK (audience IN ('conclave.desktop.management', 'conclave.profile-lab.management')),
  created_at TEXT NOT NULL,
  last_used_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  revoked_at TEXT
);

CREATE INDEX idx_desktop_human_sessions_user
  ON desktop_human_sessions(user_id, created_at DESC);

CREATE TABLE workspace_worker_inventory (
  worker_id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  owner_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  worker_type_id TEXT NOT NULL,
  activation_state TEXT NOT NULL CHECK (activation_state IN ('enabled', 'disabled')),
  readiness_state TEXT NOT NULL CHECK (readiness_state IN (
    'not_probed', 'ready', 'setup_required', 'sign_in_required',
    'worker_runtime_unavailable', 'test_failed'
  )),
  readiness_issue_code TEXT,
  provider_tool_name TEXT,
  provider_tool_version TEXT,
  capabilities_json TEXT NOT NULL DEFAULT '[]',
  local_concurrency_limit INTEGER NOT NULL CHECK (local_concurrency_limit BETWEEN 1 AND 1024),
  revision INTEGER NOT NULL CHECK (revision > 0),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  last_seen_at TEXT NOT NULL,
  engine_version TEXT,
  profile_definition_id TEXT,
  profile_release_version INTEGER CHECK (
    profile_release_version IS NULL OR profile_release_version > 0
  ),
  FOREIGN KEY (workspace_id, owner_user_id)
    REFERENCES execution_workspaces(id, owner_user_id)
);

CREATE INDEX idx_workspace_worker_inventory_owner
  ON workspace_worker_inventory(owner_user_id, updated_at);

CREATE INDEX idx_workspace_worker_inventory_workspace
  ON workspace_worker_inventory(workspace_id, worker_type_id);

CREATE TABLE worker_scheduling (
  worker_id TEXT PRIMARY KEY REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  state TEXT NOT NULL DEFAULT 'disabled' CHECK (state IN ('enabled', 'disabled', 'draining')),
  cloud_concurrency_limit INTEGER CHECK (cloud_concurrency_limit IS NULL OR cloud_concurrency_limit BETWEEN 1 AND 1024),
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  drain_requested_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  drain_requested_at TEXT,
  drain_completed_at TEXT
);

CREATE TABLE worker_scheduling_audit (
  id TEXT PRIMARY KEY,
  worker_id TEXT NOT NULL REFERENCES workspace_worker_inventory(worker_id) ON DELETE CASCADE,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN ('enabled', 'disabled', 'drain_requested', 'drain_completed')),
  requested_at TEXT NOT NULL,
  completed_at TEXT,
  details_json TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX idx_worker_scheduling_audit_worker
  ON worker_scheduling_audit(worker_id, requested_at);

CREATE TABLE workstream_work_configs (
  workstream_id TEXT PRIMARY KEY REFERENCES workstreams(id) ON DELETE CASCADE,
  config_json TEXT NOT NULL DEFAULT '{"defaultWorkflowId":"full_cycle","bindings":{}}',
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE workstream_runtime_leases (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  workspace_id TEXT NOT NULL REFERENCES execution_workspaces(id) ON DELETE RESTRICT,
  fencing_token INTEGER NOT NULL CHECK (fencing_token > 0),
  status TEXT NOT NULL CHECK (status IN ('active', 'released', 'expired')),
  acquired_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  released_at TEXT,
  UNIQUE (workstream_id, fencing_token)
);

CREATE UNIQUE INDEX idx_workstream_one_active_runtime_lease
  ON workstream_runtime_leases(workstream_id) WHERE status = 'active';

CREATE INDEX idx_workstream_runtime_lease_request
  ON workstream_runtime_leases(work_request_id, status);

CREATE TABLE realtime_event_cursors (
  stream_kind TEXT NOT NULL DEFAULT 'execution_workspace' CHECK (stream_kind IN ('execution_workspace', 'project', 'user')),
  stream_id TEXT,
  workspace_id TEXT,
  next_sequence INTEGER NOT NULL DEFAULT 0,
  CHECK (COALESCE(stream_id, workspace_id) IS NOT NULL)
);

CREATE UNIQUE INDEX idx_realtime_event_cursor_stream
  ON realtime_event_cursors(stream_kind, COALESCE(stream_id, workspace_id));

CREATE TABLE realtime_events (
  event_id TEXT PRIMARY KEY,
  stream_kind TEXT NOT NULL DEFAULT 'execution_workspace' CHECK (stream_kind IN ('execution_workspace', 'project', 'user')),
  stream_id TEXT,
  workspace_id TEXT,
  workstream_id TEXT,
  project_id TEXT,
  run_id TEXT,
  task_id TEXT,
  attempt_id TEXT,
  assignment_id TEXT,
  workspace_runtime_id TEXT,
  sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  CHECK (COALESCE(stream_id, workspace_id) IS NOT NULL),
  CHECK ((stream_kind = 'execution_workspace' AND workspace_id IS NOT NULL AND (stream_id IS NULL OR stream_id = workspace_id)) OR
         (stream_kind <> 'execution_workspace' AND workspace_id IS NULL AND stream_id IS NOT NULL))
);

CREATE UNIQUE INDEX idx_realtime_events_stream_sequence
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), sequence);
CREATE UNIQUE INDEX idx_realtime_events_stream_idempotency
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), idempotency_key);

CREATE INDEX idx_realtime_events_workspace_sequence
  ON realtime_events(workspace_id, sequence);

CREATE INDEX idx_realtime_events_occurred_at
  ON realtime_events(occurred_at, event_id);

CREATE UNIQUE INDEX idx_runs_workflow_instance
  ON runs(workflow_instance_id)
  WHERE workflow_instance_id IS NOT NULL;

CREATE TABLE worker_catalog (
  worker_type_id TEXT PRIMARY KEY,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  description TEXT NOT NULL DEFAULT '',
  lifecycle_state TEXT NOT NULL DEFAULT 'active'
    CHECK (lifecycle_state IN ('active', 'retired')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  engine_family TEXT NOT NULL DEFAULT 'cli' CHECK (engine_family = 'cli'),
  visibility_state TEXT NOT NULL DEFAULT 'visible' CHECK (
    visibility_state IN ('hidden', 'visible')
  ),
  release_stage TEXT NOT NULL DEFAULT 'stable' CHECK (
    release_stage IN ('testing', 'beta', 'stable')
  ),
  capabilities_json TEXT NOT NULL DEFAULT '["text"]'
  CHECK (
    json_valid(capabilities_json)
    AND json_type(capabilities_json) = 'array'
    AND length(capabilities_json) <= 2048
  ),
  sort_order INTEGER NOT NULL DEFAULT 100 CHECK (
    sort_order >= 0 AND sort_order <= 10000
  )
);

CREATE TABLE tool_profile_definitions (
  profile_definition_id TEXT PRIMARY KEY,
  worker_type_id TEXT NOT NULL REFERENCES worker_catalog(worker_type_id) ON DELETE RESTRICT,
  display_name TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 128),
  provider_tool_name TEXT NOT NULL CHECK (length(provider_tool_name) BETWEEN 1 AND 128),
  engine_family TEXT NOT NULL CHECK (engine_family = 'cli'),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  lifecycle_state TEXT NOT NULL DEFAULT 'active'
    CHECK (lifecycle_state IN ('active', 'retired')),
  created_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (profile_definition_id, worker_type_id)
);

CREATE INDEX idx_tool_profile_definitions_worker
  ON tool_profile_definitions(worker_type_id, lifecycle_state, profile_definition_id);

-- Authoring-only templates: never releases or Workspace admissions.
CREATE TABLE tool_profile_starter_templates (
  profile_definition_id TEXT PRIMARY KEY REFERENCES tool_profile_definitions(profile_definition_id) ON DELETE CASCADE,
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  profile_json TEXT NOT NULL CHECK (json_valid(profile_json)
    AND json_extract(profile_json, '$.schemaVersion') = 1
    AND json_extract(profile_json, '$.profileDefinitionId') = profile_definition_id
    AND json_extract(profile_json, '$.releaseVersion') = 1),
  updated_at TEXT NOT NULL
);

CREATE TABLE tool_profile_releases (
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL CHECK (release_version BETWEEN 1 AND 2147483647),
  worker_type_id TEXT NOT NULL,
  lifecycle_state TEXT NOT NULL DEFAULT 'draft'
    CHECK (lifecycle_state IN ('draft', 'testing', 'beta', 'stable', 'retired', 'revoked')),
  schema_version INTEGER NOT NULL CHECK (schema_version = 1),
  engine_family TEXT NOT NULL CHECK (engine_family = 'cli'),
  engine_compatibility_min TEXT NOT NULL,
  engine_compatibility_max_exclusive TEXT NOT NULL,
  payload_json TEXT NOT NULL CHECK (length(payload_json) <= 262144),
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  signature TEXT,
  signing_key_id TEXT,
  publisher TEXT,
  created_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  published_at TEXT,
  lifecycle_reason TEXT,
  revoked_at TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (profile_definition_id, release_version),
  FOREIGN KEY (profile_definition_id, worker_type_id)
    REFERENCES tool_profile_definitions(profile_definition_id, worker_type_id)
    ON DELETE RESTRICT,
  CHECK ((published_at IS NULL AND signature IS NULL AND signing_key_id IS NULL)
      OR (published_at IS NOT NULL AND signature IS NOT NULL AND signing_key_id IS NOT NULL AND publisher IS NOT NULL))
);

CREATE INDEX idx_tool_profile_release_lifecycle
  ON tool_profile_releases(profile_definition_id, lifecycle_state, release_version DESC);

CREATE INDEX idx_tool_profile_release_worker
  ON tool_profile_releases(worker_type_id, lifecycle_state, profile_definition_id);

CREATE TABLE tool_profile_channel_pointers (
  profile_definition_id TEXT NOT NULL,
  channel TEXT NOT NULL CHECK (channel IN ('testing', 'beta', 'stable')),
  release_version INTEGER NOT NULL,
  modified_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (profile_definition_id, channel),
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE TABLE tool_profile_release_audit (
  id TEXT PRIMARY KEY,
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL,
  actor_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  action TEXT NOT NULL CHECK (action IN (
    'draft_created', 'published_for_testing', 'promoted_to_beta',
    'promoted_to_stable', 'retired', 'revoked', 'channel_promoted',
    'stable_rollback', 'channel_cleared'
  )),
  previous_release_version INTEGER,
  channel TEXT CHECK (channel IS NULL OR channel IN ('testing', 'beta', 'stable')),
  from_state TEXT,
  to_state TEXT,
  reason TEXT,
  details_json TEXT NOT NULL DEFAULT '{}',
  created_at TEXT NOT NULL,
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE INDEX idx_tool_profile_release_audit_history
  ON tool_profile_release_audit(profile_definition_id, release_version, created_at);

CREATE TRIGGER tool_profile_release_payload_immutable
BEFORE UPDATE OF profile_definition_id, release_version, worker_type_id,
  schema_version, engine_family, engine_compatibility_min,
  engine_compatibility_max_exclusive, payload_json, payload_digest,
  signature, signing_key_id, publisher, published_at
ON tool_profile_releases
WHEN OLD.published_at IS NOT NULL AND (
  OLD.profile_definition_id IS NOT NEW.profile_definition_id OR
  OLD.release_version IS NOT NEW.release_version OR
  OLD.worker_type_id IS NOT NEW.worker_type_id OR
  OLD.schema_version IS NOT NEW.schema_version OR
  OLD.engine_family IS NOT NEW.engine_family OR
  OLD.engine_compatibility_min IS NOT NEW.engine_compatibility_min OR
  OLD.engine_compatibility_max_exclusive IS NOT NEW.engine_compatibility_max_exclusive OR
  OLD.payload_json IS NOT NEW.payload_json OR
  OLD.payload_digest IS NOT NEW.payload_digest OR
  OLD.signature IS NOT NEW.signature OR
  OLD.signing_key_id IS NOT NEW.signing_key_id OR
  OLD.publisher IS NOT NEW.publisher OR
  OLD.published_at IS NOT NEW.published_at
)
BEGIN
  SELECT RAISE(ABORT, 'published Tool Profile release payload is immutable');
END;

CREATE TRIGGER tool_profile_published_release_no_delete
BEFORE DELETE ON tool_profile_releases
WHEN OLD.published_at IS NOT NULL
BEGIN
  SELECT RAISE(ABORT, 'published Tool Profile releases cannot be deleted');
END;

CREATE TRIGGER tool_profile_lifecycle_transition_valid
BEFORE UPDATE OF lifecycle_state ON tool_profile_releases
WHEN OLD.lifecycle_state IS NOT NEW.lifecycle_state AND NOT (
  (OLD.lifecycle_state = 'draft' AND NEW.lifecycle_state IN ('testing', 'retired', 'revoked')) OR
  (OLD.lifecycle_state = 'testing' AND NEW.lifecycle_state IN ('beta', 'stable', 'retired', 'revoked')) OR
  (OLD.lifecycle_state = 'beta' AND NEW.lifecycle_state IN ('stable', 'retired', 'revoked')) OR
  (OLD.lifecycle_state = 'stable' AND NEW.lifecycle_state IN ('retired', 'revoked'))
)
BEGIN
  SELECT RAISE(ABORT, 'invalid Tool Profile lifecycle transition');
END;

CREATE TRIGGER tool_profile_release_draft_audit
AFTER INSERT ON tool_profile_releases
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    to_state, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.created_by_user_id, 'draft_created', NEW.lifecycle_state, NEW.created_at
  );
END;

CREATE TRIGGER tool_profile_release_lifecycle_audit
AFTER UPDATE OF lifecycle_state ON tool_profile_releases
WHEN OLD.lifecycle_state IS NOT NEW.lifecycle_state
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    from_state, to_state, reason, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.updated_by_user_id,
    CASE NEW.lifecycle_state
      WHEN 'testing' THEN 'published_for_testing'
      WHEN 'beta' THEN 'promoted_to_beta'
      WHEN 'stable' THEN 'promoted_to_stable'
      WHEN 'retired' THEN 'retired'
      WHEN 'revoked' THEN 'revoked'
    END,
    OLD.lifecycle_state, NEW.lifecycle_state, NEW.lifecycle_reason, NEW.updated_at
  );
END;

CREATE TRIGGER tool_profile_channel_target_valid_insert
BEFORE INSERT ON tool_profile_channel_pointers
WHEN NOT EXISTS (
  SELECT 1 FROM tool_profile_releases release
   WHERE release.profile_definition_id = NEW.profile_definition_id
     AND release.release_version = NEW.release_version
     AND release.published_at IS NOT NULL
     AND release.lifecycle_state = NEW.channel
)
BEGIN
  SELECT RAISE(ABORT, 'channel pointer must target an eligible published release');
END;

CREATE TRIGGER tool_profile_channel_target_valid_update
BEFORE UPDATE OF profile_definition_id, channel, release_version
ON tool_profile_channel_pointers
WHEN NOT EXISTS (
  SELECT 1 FROM tool_profile_releases release
   WHERE release.profile_definition_id = NEW.profile_definition_id
     AND release.release_version = NEW.release_version
     AND release.published_at IS NOT NULL
     AND release.lifecycle_state = NEW.channel
)
BEGIN
  SELECT RAISE(ABORT, 'channel pointer must target an eligible published release');
END;

CREATE TRIGGER tool_profile_channel_insert_audit
AFTER INSERT ON tool_profile_channel_pointers
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    channel, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.modified_by_user_id, 'channel_promoted', NEW.channel, NEW.updated_at
  );
END;

CREATE TRIGGER tool_profile_channel_update_audit
AFTER UPDATE OF release_version ON tool_profile_channel_pointers
WHEN OLD.release_version IS NOT NEW.release_version
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    previous_release_version, channel, created_at
  ) VALUES (
    lower(hex(randomblob(16))), NEW.profile_definition_id, NEW.release_version,
    NEW.modified_by_user_id,
    CASE WHEN NEW.channel = 'stable' AND NEW.release_version < OLD.release_version
      THEN 'stable_rollback' ELSE 'channel_promoted' END,
    OLD.release_version, NEW.channel, NEW.updated_at
  );
END;

CREATE TRIGGER tool_profile_channel_delete_audit
AFTER DELETE ON tool_profile_channel_pointers
BEGIN
  INSERT INTO tool_profile_release_audit (
    id, profile_definition_id, release_version, actor_user_id, action,
    previous_release_version, channel, created_at
  ) VALUES (
    lower(hex(randomblob(16))), OLD.profile_definition_id, OLD.release_version,
    OLD.modified_by_user_id, 'channel_cleared', OLD.release_version,
    OLD.channel, datetime('now')
  );
END;

CREATE TRIGGER tool_profile_release_clear_revoked_channels
AFTER UPDATE OF lifecycle_state ON tool_profile_releases
WHEN NEW.lifecycle_state IN ('retired', 'revoked')
BEGIN
  DELETE FROM tool_profile_channel_pointers
   WHERE profile_definition_id = NEW.profile_definition_id
     AND release_version = NEW.release_version;
END;

CREATE TABLE workspace_tool_profile_channels (
  workspace_id TEXT PRIMARY KEY
    REFERENCES execution_workspaces(id) ON DELETE CASCADE,
  channel TEXT NOT NULL CHECK (channel IN ('testing', 'beta', 'stable')),
  updated_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_workspace_tool_profile_channels_channel
  ON workspace_tool_profile_channels(channel);

CREATE TABLE tool_profile_acceptance_evidence (
  id TEXT PRIMARY KEY,
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL,
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  engine_version TEXT NOT NULL,
  provider_tool_version TEXT NOT NULL,
  evidence_json TEXT NOT NULL CHECK (length(evidence_json) <= 32768),
  submitted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  accepted_at TEXT NOT NULL,
  submitted_at TEXT NOT NULL,
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE TABLE tool_profile_local_qualification_evidence (
  id TEXT PRIMARY KEY,
  profile_definition_id TEXT NOT NULL,
  release_version INTEGER NOT NULL,
  payload_digest TEXT NOT NULL CHECK (length(payload_digest) = 64),
  engine_version TEXT NOT NULL,
  provider_tool_version TEXT NOT NULL,
  evidence_json TEXT NOT NULL CHECK (length(evidence_json) <= 32768),
  submitted_by_user_id TEXT REFERENCES users(id) ON DELETE SET NULL,
  qualified_at TEXT NOT NULL,
  submitted_at TEXT NOT NULL,
  FOREIGN KEY (profile_definition_id, release_version)
    REFERENCES tool_profile_releases(profile_definition_id, release_version)
    ON DELETE RESTRICT
);

CREATE INDEX idx_tool_profile_local_qualification_release
  ON tool_profile_local_qualification_evidence(profile_definition_id, release_version, submitted_at DESC);

CREATE TRIGGER tool_profile_local_qualification_immutable
BEFORE UPDATE ON tool_profile_local_qualification_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile local qualification evidence is immutable');
END;

CREATE TRIGGER tool_profile_local_qualification_no_delete
BEFORE DELETE ON tool_profile_local_qualification_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile local qualification evidence cannot be deleted');
END;

CREATE INDEX idx_tool_profile_acceptance_evidence_release
  ON tool_profile_acceptance_evidence(profile_definition_id, release_version, submitted_at DESC);

CREATE TRIGGER tool_profile_acceptance_evidence_immutable
BEFORE UPDATE ON tool_profile_acceptance_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile acceptance evidence is immutable');
END;

CREATE TRIGGER tool_profile_acceptance_evidence_no_delete
BEFORE DELETE ON tool_profile_acceptance_evidence
BEGIN
  SELECT RAISE(ABORT, 'Tool Profile acceptance evidence cannot be deleted');
END;

CREATE UNIQUE INDEX idx_tool_profile_one_active_definition_per_worker
  ON tool_profile_definitions(worker_type_id)
  WHERE lifecycle_state = 'active';

CREATE TABLE work_requests (
  id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  mode TEXT NOT NULL CHECK (mode IN ('stateless', 'stateful')),
  workflow_id TEXT NOT NULL CHECK (
    workflow_id IN ('direct', 'research', 'plan_implement', 'implement_verify', 'full_cycle')
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

CREATE INDEX idx_work_requests_workstream
  ON work_requests(workstream_id, status, created_at);

CREATE TABLE workflow_tasks (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  step_kind TEXT NOT NULL CHECK (
    step_kind IN ('research', 'plan', 'implement', 'test', 'verify')
  ),
  execution_mode TEXT NOT NULL CHECK (
    execution_mode IN ('stateless_read', 'stateful_workstream')
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

CREATE TABLE workflow_task_dependencies (
  task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE CASCADE,
  depends_on_task_id TEXT NOT NULL REFERENCES workflow_tasks(id) ON DELETE RESTRICT,
  PRIMARY KEY (task_id, depends_on_task_id),
  CHECK (task_id <> depends_on_task_id)
);

CREATE INDEX idx_workflow_tasks_request
  ON workflow_tasks(work_request_id, status, created_at);

CREATE TRIGGER trg_work_requests_snapshot_immutable
BEFORE UPDATE OF workstream_id, requested_by_user_id, mode, workflow_id,
  workflow_version, workflow_snapshot_json, snapshot_json,
  primary_workspace_id, input_json
ON work_requests
WHEN OLD.workstream_id IS NOT NEW.workstream_id
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

-- Canonical logical Workers and official CLI Profile definitions.
INSERT INTO worker_catalog (
  worker_type_id, display_name, description, lifecycle_state, engine_family,
  visibility_state, release_stage, capabilities_json, sort_order,
  created_at, updated_at
) VALUES
  (
    'chatgpt',
    'ChatGPT',
    'Logical Worker implemented by approved local tools.',
    'active',
    'cli',
    'visible',
    'stable',
    '["text","local_file","workstream_read","workstream_write","durable_session"]',
    10,
    '2026-10-01T00:00:00Z',
    '2026-10-01T00:00:00Z'
  ),
  (
    'gemini',
    'Gemini',
    'Logical Worker implemented by approved local tools.',
    'active',
    'cli',
    'visible',
    'stable',
    '["text","local_file","workstream_read","workstream_write","durable_session"]',
    20,
    '2026-10-01T00:00:00Z',
    '2026-10-01T00:00:00Z'
  );

INSERT INTO tool_profile_definitions (
  profile_definition_id, worker_type_id, display_name, provider_tool_name,
  engine_family, schema_version, lifecycle_state, created_at, updated_at
) VALUES
  (
    'chatgpt-codex',
    'chatgpt',
    'ChatGPT Codex',
    'codex',
    'cli',
    1,
    'active',
    '2026-10-01T00:00:00Z',
    '2026-10-01T00:00:00Z'
  ),
  (
    'gemini-antigravity',
    'gemini',
    'Gemini Antigravity',
    'agy',
    'cli',
    1,
    'active',
    '2026-10-01T00:00:00Z',
    '2026-10-01T00:00:00Z'
  );

-- Tested v1 payloads are starter drafts, not qualified or signed releases.
INSERT OR IGNORE INTO tool_profile_starter_templates (profile_definition_id, schema_version, profile_json, updated_at) VALUES ('chatgpt-codex', 1, '{"schemaVersion":1,"profileDefinitionId":"chatgpt-codex","releaseVersion":1,"logicalWorkerTypeId":"chatgpt","engineFamily":"cli","engineCompatibility":{"min":"1.0.0","maxExclusive":"2.0.0"},"providerTool":{"name":"Codex CLI","executableCandidates":["codex"],"discovery":{"standardLocations":["{{home}}/.local/bin","/usr/local/bin"],"allowPathSearch":true},"versionProbe":{"arguments":["--version"],"timeoutMs":10000,"source":"stdout","extract":{"kind":"regex_capture","patternId":"semver"}},"supportedVersions":[{"min":"0.158.0","maxExclusive":"0.190.0"}]},"environment":{"passthrough":["PATH","HOME","USERPROFILE","TMP","TEMP","TMPDIR","LANG","LC_ALL","SSL_CERT_FILE","SSL_CERT_DIR","CODEX_HOME","OPENAI_API_KEY"],"set":{"NO_COLOR":"1"}},"probe":{"passive":{"checks":[{"id":"authentication","arguments":["login","status"],"timeoutMs":10000,"successExitCodes":[0],"failureIssueCode":"provider_authentication_required"}],"configChecks":[]},"live":{"timeoutMs":30000,"expectedFinalText":{"kind":"exact","value":"OK"}}},"execution":{"arguments":["--ask-for-approval","never",{"sandboxPolicyMapping":true},"exec","--json","--color","never","--skip-git-repo-check","--cd","{{workingDirectory}}",{"modelArguments":true},{"sessionResumeArguments":true},{"ifAbsent":"sessionId","ifSessionPolicy":"stateless","values":["--ephemeral"]},{"providerTimeoutArguments":true},"-"],"stdin":{"mode":"raw_text","value":"{{prompt}}"},"output":{"mode":"jsonl"},"events":[{"when":[{"kind":"equals","selector":"$.type","value":"thread.started"}],"actions":[{"type":"set_session","selector":"$.thread_id"}]},{"when":[{"kind":"equals","selector":"$.type","value":"turn.completed"}],"actions":[{"type":"mark_success"}]},{"when":[{"kind":"equals","selector":"$.type","value":"item.completed"},{"kind":"equals","selector":"$.item.type","value":"agent_message"}],"actions":[{"type":"set_final_text","selector":"$.item.text"}]},{"when":[{"kind":"equals","selector":"$.type","value":"turn.failed"}],"actions":[{"type":"set_provider_error","selector":"$.error.message"},{"type":"mark_failure"}]},{"when":[{"kind":"equals","selector":"$.type","value":"error"}],"actions":[{"type":"set_provider_error","selector":"$.message"},{"type":"mark_failure"}]}]},"session":{"supported":true,"formatId":"codex-thread-v1","compatibleFormatIds":["codex-thread-v1"],"extract":"$.thread_id","resumeArguments":["resume","{{sessionId}}"],"requireObservedIdMatch":true},"model":{"supported":true,"arguments":["--model","{{model}}"],"unknownModelPolicy":"pass_through"},"timeout":{"providerArguments":[],"providerReserveMs":2000},"sandbox":{"mappings":{"restricted":["--sandbox","workspace-write"],"provider_default":["--sandbox","read-only"],"full_access":["--dangerously-bypass-approvals-and-sandbox"]}},"progress":[{"when":[{"kind":"equals","selector":"$.type","value":"turn.started"}],"percentage":10,"messageKey":"provider_working"},{"when":[{"kind":"one_of","selector":"$.type","values":["item.started","item.updated","item.completed"]},{"kind":"one_of","selector":"$.item.type","values":["command_execution","mcp_tool_call","web_search_call"]}],"percentage":45,"messageKey":"provider_tool_started"}],"errors":{"mappings":[{"evidence":{"kind":"stderr_pattern","patternId":"cancelled"},"issueCode":"cancelled"},{"evidence":{"kind":"stderr_pattern","patternId":"deadline_exceeded"},"issueCode":"deadline_exceeded"},{"evidence":{"kind":"stderr_pattern","patternId":"provider_authentication_required"},"issueCode":"provider_authentication_required"},{"evidence":{"kind":"stderr_pattern","patternId":"permission_denied"},"issueCode":"permission_denied"},{"evidence":{"kind":"structured_provider_error","selector":"$.error.message"},"issueCode":"provider_failure"},{"evidence":{"kind":"missing_terminal"},"issueCode":"provider_failure"}]},"capabilities":["text","local_file","durable_session"],"compatibilityOverrides":[{"providerVersion":{"min":"0.180.0","maxExclusive":"0.181.0"},"executionArguments":["exec",{"sandboxPolicyMapping":true},{"modelArguments":true},{"sessionResumeArguments":true},{"providerTimeoutArguments":true},"--json","-"]}]}', '2026-10-04T00:00:00Z');
INSERT OR IGNORE INTO tool_profile_starter_templates (profile_definition_id, schema_version, profile_json, updated_at) VALUES ('gemini-antigravity', 1, '{"schemaVersion":1,"profileDefinitionId":"gemini-antigravity","releaseVersion":1,"logicalWorkerTypeId":"gemini","engineFamily":"cli","engineCompatibility":{"min":"1.0.0","maxExclusive":"2.0.0"},"providerTool":{"name":"Antigravity CLI","executableCandidates":["agy"],"discovery":{"standardLocations":["{{home}}/.local/bin","{{home}}/.gemini/antigravity-cli/bin"],"allowPathSearch":true},"versionProbe":{"arguments":["--version"],"timeoutMs":10000,"source":"stdout","extract":{"kind":"regex_capture","patternId":"semver"}},"supportedVersions":[{"min":"1.0.0","maxExclusive":"2.0.0"}]},"environment":{"passthrough":["PATH","HOME","USERPROFILE","ProgramFiles","TMP","TEMP","TMPDIR","LANG","LC_ALL","SSL_CERT_FILE","SSL_CERT_DIR","AGY_ADC_AUTH","GEMINI_API_KEY","GOOGLE_API_KEY","GOOGLE_APPLICATION_CREDENTIALS","GOOGLE_CLOUD_PROJECT","GOOGLE_CLOUD_LOCATION","GOOGLE_GEMINI_BASE_URL"],"set":{}},"probe":{"passive":{"checks":[],"configChecks":[{"id":"gemini-provider-config","root":"home","relativePath":".gemini/antigravity-cli/settings.json","format":"json","maxBytes":16384,"onMissing":"warning","onInvalid":"failed","onNoMatch":{"result":"passed"},"rules":[{"when":[{"kind":"equals","selector":"$.modelProvider","value":"gemini"}],"result":"passed","requiredEnvironmentAny":["GEMINI_API_KEY"],"whenEnvironmentMissing":{"result":"failed","issueCode":"provider_authentication_required"}},{"when":[{"kind":"exists","selector":"$.modelProvider","exists":true}],"result":"failed","issueCode":"provider_failure"}]}]},"live":{"timeoutMs":30000,"expectedFinalText":{"kind":"exact","value":"OK"}}},"execution":{"arguments":["--input-format","stream-json","--output-format","stream-json",{"sandboxPolicyMapping":true},{"providerTimeoutArguments":true},{"sessionResumeArguments":true},{"modelArguments":true}],"stdin":{"mode":"json_object","value":{"event":"user","message":{"content":"{{prompt}}"}},"appendNewline":true},"output":{"mode":"jsonl"},"events":[{"when":[{"kind":"equals","selector":"$.event","value":"init"}],"actions":[{"type":"set_session","selector":"$.conversation_id"}]},{"when":[{"kind":"equals","selector":"$.event","value":"result"},{"kind":"not_equals","selector":"$.result.status","value":"SUCCESS"}],"actions":[{"type":"set_provider_error","selector":"$.result.error"},{"type":"mark_failure"}]},{"when":[{"kind":"equals","selector":"$.event","value":"result"},{"kind":"equals","selector":"$.result.status","value":"SUCCESS"}],"actions":[{"type":"set_final_text","selector":"$.result.response"},{"type":"mark_success"}]},{"when":[{"kind":"equals","selector":"$.event","value":"result"}],"actions":[{"type":"set_session","selector":"$.result.conversation_id"},{"type":"set_terminal_status","selector":"$.result.status"}]}]},"session":{"supported":true,"formatId":"antigravity-conversation-v1","compatibleFormatIds":["antigravity-conversation-v1"],"extract":"$.conversation_id","resumeArguments":["--conversation","{{sessionId}}"],"requireObservedIdMatch":true},"model":{"supported":true,"arguments":["--model","{{model}}"],"unknownModelPolicy":"pass_through"},"timeout":{"providerArguments":["--print-timeout","{{timeoutSeconds}}s"],"providerReserveMs":1500},"sandbox":{"mappings":{"restricted":["--sandbox","--mode","accept-edits"],"provider_default":["--sandbox"],"full_access":[]}},"progress":[{"when":[{"kind":"equals","selector":"$.event","value":"step_update"},{"kind":"equals","selector":"$.step_update.state","value":"ACTIVE"},{"kind":"equals","selector":"$.step_update.step_type","value":"agent_response"}],"percentage":40,"messageKey":"provider_response_received"},{"when":[{"kind":"equals","selector":"$.event","value":"step_update"},{"kind":"equals","selector":"$.step_update.state","value":"ACTIVE"},{"kind":"type_is","selector":"$.step_update.step_type","value":"string"}],"percentage":40,"messageKey":"provider_working"}],"errors":{"mappings":[{"evidence":{"kind":"stderr_pattern","patternId":"cancelled"},"issueCode":"cancelled"},{"evidence":{"kind":"stderr_pattern","patternId":"deadline_exceeded"},"issueCode":"deadline_exceeded"},{"evidence":{"kind":"stderr_pattern","patternId":"provider_tool_unavailable"},"issueCode":"provider_tool_unavailable"},{"evidence":{"kind":"stderr_pattern","patternId":"provider_authentication_required"},"issueCode":"provider_authentication_required"},{"evidence":{"kind":"stderr_pattern","patternId":"permission_denied"},"issueCode":"permission_denied"},{"evidence":{"kind":"terminal_status","value":"ERROR"},"issueCode":"provider_failure"},{"evidence":{"kind":"missing_terminal"},"issueCode":"provider_failure"}]},"capabilities":["text","local_file","durable_session"],"compatibilityOverrides":[]}', '2026-10-04T00:00:00Z');

-- Human Product Protocol v1: permanent receipts for explicit mutation retries.
-- No TTL: forgetting a key could execute expensive work twice.
CREATE TABLE mutation_receipts (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  scope TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  request_hash TEXT NOT NULL,
  response_json TEXT NOT NULL,
  response_status INTEGER NOT NULL CHECK (response_status BETWEEN 200 AND 299),
  created_at TEXT NOT NULL,
  PRIMARY KEY (user_id, scope, idempotency_key)
);
