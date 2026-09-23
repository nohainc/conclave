-- Optional clean development seed for Architecture v4.
-- No users, workspaces, credentials, or assignments are seeded.
-- Worker catalog rows are intentionally global and contain no secrets.
INSERT INTO workers (id, display_name, description, publisher, status, created_at, updated_at)
VALUES
  ('codex', 'Codex Worker', 'Local coding and repository execution worker.', 'Conclave', 'active', '2026-09-23T00:00:00Z', '2026-09-23T00:00:00Z'),
  ('openai', 'OpenAI Worker', 'OpenAI API execution worker.', 'Conclave', 'active', '2026-09-23T00:00:00Z', '2026-09-23T00:00:00Z'),
  ('git-test', 'Git/Test Worker', 'Repository and CI evidence worker.', 'Conclave', 'active', '2026-09-23T00:00:00Z', '2026-09-23T00:00:00Z');
