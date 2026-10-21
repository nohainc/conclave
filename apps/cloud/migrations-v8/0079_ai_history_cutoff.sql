-- Clearing AI History no longer deletes or copies Work: it records a cutoff.
-- AI History shows only Work Requests created after `ai_history_cleared_at`;
-- the Conversation keeps every request and answer unchanged.
ALTER TABLE threads ADD COLUMN ai_history_cleared_at TEXT;
-- Worker context starts after this canonical history sequence, so cleared
-- exchanges stay readable but are never sent to a later Worker session.
ALTER TABLE conversations
  ADD COLUMN context_floor_sequence INTEGER NOT NULL DEFAULT 0;
