-- Files a user uploaded as Work Request or discussion inputs. The bytes live
-- in R2 at work-request-inputs/<id>; this row is the owner's accounting
-- record for My Files and the per-user storage quota. thread_id and space_id
-- are plain links without foreign keys, like user_notes: deleting a Thread
-- keeps the file until its owner deletes it.
CREATE TABLE user_files (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  thread_id TEXT,
  space_id TEXT,
  name TEXT NOT NULL,
  media_type TEXT NOT NULL,
  size_bytes INTEGER NOT NULL CHECK (size_bytes >= 0),
  created_at TEXT NOT NULL
);
-- Covers both the newest-first listing and the SUM() for quota checks.
CREATE INDEX idx_user_files_user ON user_files(user_id, created_at, size_bytes);
