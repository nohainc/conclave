-- Private notes. A note belongs to its user, never to a Space or Thread, so
-- deleting a Thread or Space (or leaving it) keeps the note. thread_id and
-- space_id are plain links without foreign keys; reads treat a link to a
-- Thread the user can no longer see as detached and show the saved title.
CREATE TABLE user_notes (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  thread_id TEXT,
  space_id TEXT,
  linked_title TEXT,
  revision INTEGER NOT NULL DEFAULT 1,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_user_notes_user ON user_notes(user_id, updated_at);
-- At most one note per user and Thread: the Thread's Notes tab.
CREATE UNIQUE INDEX idx_user_notes_thread
  ON user_notes(user_id, thread_id) WHERE thread_id IS NOT NULL;
