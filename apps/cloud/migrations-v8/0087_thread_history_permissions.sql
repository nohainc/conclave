-- Keep contribution eligibility even after messages/conversations are cleared.
ALTER TABLE threads ADD COLUMN has_other_contributions INTEGER NOT NULL DEFAULT 0
  CHECK (has_other_contributions IN (0, 1));
-- Earlier hard deletions cannot be reconstructed reliably. Existing threads
-- conservatively require their Space owner for destructive cleanup.
UPDATE threads SET has_other_contributions = 1;
ALTER TABLE discussion_messages ADD COLUMN event_type TEXT;
CREATE TRIGGER trg_thread_discussion_contributor AFTER INSERT ON discussion_messages
WHEN NEW.event_type IS NULL AND NEW.kind != 'ai_answer'
BEGIN
  UPDATE threads SET has_other_contributions = 1
  WHERE id = NEW.thread_id AND lead_user_id != NEW.author_user_id;
END;
CREATE TRIGGER trg_thread_request_contributor AFTER INSERT ON work_requests
BEGIN
  UPDATE threads SET has_other_contributions = 1
  WHERE id = NEW.thread_id AND lead_user_id != NEW.requested_by_user_id;
END;

ALTER TABLE threads ADD COLUMN ai_context_generation INTEGER NOT NULL DEFAULT 0;
ALTER TABLE work_requests ADD COLUMN ai_context_generation INTEGER NOT NULL DEFAULT 0;
CREATE TRIGGER trg_request_ai_generation AFTER INSERT ON work_requests
BEGIN
  UPDATE work_requests SET ai_context_generation =
    (SELECT ai_context_generation FROM threads WHERE id = NEW.thread_id)
    WHERE id = NEW.id;
END;
