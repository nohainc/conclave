-- Requests a Thread's members send while earlier requests are processing.
-- Shared by every member and sent by Cloud, as their author, one at a time
-- when the Thread has nothing processing. `sending` marks the item Cloud is
-- currently turning into a Work request.
CREATE TABLE thread_request_queue (
  id TEXT PRIMARY KEY,
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  author_user_id TEXT NOT NULL,
  request_json TEXT NOT NULL,
  position REAL NOT NULL,
  status TEXT NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'sending')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE INDEX idx_thread_request_queue_thread
  ON thread_request_queue(thread_id, position);

-- One row per paused queue; no row means the queue is running. A member
-- pauses it (`user`), or a failed request or failed send does (`failure`).
CREATE TABLE thread_request_queue_state (
  thread_id TEXT PRIMARY KEY REFERENCES threads(id) ON DELETE CASCADE,
  paused_reason TEXT NOT NULL CHECK (paused_reason IN ('user', 'failure')),
  paused_by_user_id TEXT,
  failure_message TEXT,
  updated_at TEXT NOT NULL
);
