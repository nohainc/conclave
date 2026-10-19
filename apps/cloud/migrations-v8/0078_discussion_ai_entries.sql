-- Clearing Work history preserves completed AI exchanges in the Thread
-- conversation. An archived entry keeps the requesting user as its owner;
-- `kind` tells clients whether the body is the request or the Worker answer.
-- `work_request_id` is a plain reference because the Work Request is deleted.
ALTER TABLE discussion_messages
  ADD COLUMN kind TEXT NOT NULL DEFAULT 'message'
  CHECK (kind IN ('message', 'ai_request', 'ai_answer'));
ALTER TABLE discussion_messages ADD COLUMN work_request_id TEXT;
ALTER TABLE discussion_messages ADD COLUMN worker_display_name TEXT;
