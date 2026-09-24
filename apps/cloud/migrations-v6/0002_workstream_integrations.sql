-- V6-19: controlled route from Workstream output back to the Project base.
CREATE TABLE workstream_integrations (
  id TEXT PRIMARY KEY,
  project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  requested_by_user_id TEXT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  provider TEXT NOT NULL CHECK (provider IN ('github', 'patch')),
  status TEXT NOT NULL CHECK (status IN (
    'draft', 'branch_published', 'pr_open', 'merge_ready', 'merged',
    'patch_exported', 'completed', 'conflict', 'failed'
  )),
  branch_name TEXT,
  base_revision TEXT NOT NULL,
  head_revision TEXT,
  pull_request_number INTEGER,
  pull_request_url TEXT,
  patch_artifact_id TEXT REFERENCES artifacts(id) ON DELETE SET NULL,
  error TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_v6_workstream_integrations_workstream
  ON workstream_integrations(workstream_id, updated_at);
CREATE UNIQUE INDEX idx_v6_workstream_integrations_pr
  ON workstream_integrations(provider, pull_request_url)
  WHERE pull_request_url IS NOT NULL;
