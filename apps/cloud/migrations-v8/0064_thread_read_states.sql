-- Per-user Thread read markers. A Thread is unread for a user when another
-- user's Discussion message, or a finished Work Request, is newer than the
-- marker. Users without a marker fall back to their Space membership date.
CREATE TABLE thread_read_states (
  thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  read_at TEXT NOT NULL,
  PRIMARY KEY (thread_id, user_id)
);

-- Existing history starts as read; only later activity becomes unread.
INSERT INTO thread_read_states (thread_id, user_id, read_at)
SELECT t.id, m.user_id, strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
  FROM threads t
  JOIN space_memberships m ON m.space_id = t.space_id;
