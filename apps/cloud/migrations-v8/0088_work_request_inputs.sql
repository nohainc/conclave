-- Input Delivery v1: one row per file input of a Work Request. The request is
-- accepted before its files are uploaded; AX uploads each file to R2
-- (work-request-inputs/<id>), the target Workspace Service downloads it over
-- authenticated HTTPS, and the Workflow dispatches the first step only after
-- every row is `delivered`. A `failed` row fails the request before any
-- Worker starts. Attempt counters record whole-file restarts. The request's
-- input_json stays immutable: the verified digest and display previews live
-- here and are merged into dispatch and history reads.
CREATE TABLE work_request_inputs (
  id TEXT PRIMARY KEY,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  thread_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  user_id TEXT NOT NULL,
  position INTEGER NOT NULL CHECK (position >= 0),
  name TEXT NOT NULL,
  media_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
  content_digest TEXT,
  preview_text TEXT,
  preview_image TEXT,
  state TEXT NOT NULL CHECK (
    state IN ('awaiting_upload', 'uploaded', 'delivered', 'failed')
  ),
  upload_attempts INTEGER NOT NULL DEFAULT 0,
  delivery_attempts INTEGER NOT NULL DEFAULT 0,
  error_message TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (work_request_id, position)
);
-- The Service's "what can I download" poll.
CREATE INDEX idx_work_request_inputs_workspace
  ON work_request_inputs(workspace_id, state, created_at);
