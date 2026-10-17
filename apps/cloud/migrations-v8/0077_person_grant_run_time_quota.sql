-- Optional per-person run-time limit on a lent Workspace, in approximate
-- seconds per UTC calendar month (ADR-020). NULL means no limit.
ALTER TABLE workspace_person_grants
  ADD COLUMN max_run_seconds_per_month INTEGER
  CHECK (max_run_seconds_per_month IS NULL OR max_run_seconds_per_month > 0);
