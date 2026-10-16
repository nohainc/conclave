-- Per-user read markers for the notification feed. The feed itself is derived
-- from finished Work Requests (completed or failed) in Spaces the user belongs
-- to, so no event needs to be written on every status transition.
CREATE TABLE user_notification_reads (
  user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  work_request_id TEXT NOT NULL REFERENCES work_requests(id) ON DELETE CASCADE,
  read_at TEXT NOT NULL,
  PRIMARY KEY (user_id, work_request_id)
);
