-- Per-user pins. A pin only changes the pinning user's sidebar order; Space
-- settings stay owner-only and shared. Rows disappear with the user, and the
-- Cloud list reads ignore pins on Spaces or Threads the user can no longer see.
CREATE TABLE user_pins (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('space', 'thread')),
  target_id TEXT NOT NULL,
  pinned_at TEXT NOT NULL,
  PRIMARY KEY (user_id, kind, target_id)
);
