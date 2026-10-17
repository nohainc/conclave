-- Per-person concurrent request limit on a lent Workspace (ADR-020).
ALTER TABLE workspace_person_grants
  ADD COLUMN max_concurrent_requests INTEGER NOT NULL DEFAULT 1
  CHECK (max_concurrent_requests BETWEEN 1 AND 10);
