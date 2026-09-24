-- V6-22: optional fixture-preservation mapping. Clean v6 resets may leave it empty.
CREATE TABLE chat_workstream_migrations (
  chat_id TEXT PRIMARY KEY,
  workstream_id TEXT NOT NULL REFERENCES workstreams(id) ON DELETE CASCADE,
  discussion_message_ids_json TEXT NOT NULL DEFAULT '[]',
  historical_run_ids_json TEXT NOT NULL DEFAULT '[]',
  migrated_at TEXT NOT NULL
);
