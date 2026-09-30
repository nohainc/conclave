-- Session policy is Conclave-owned metadata. Provider session identifiers and
-- the opaque per-session key are never persisted by Cloud.
ALTER TABLE worker_assignments
  ADD COLUMN session_policy TEXT NOT NULL DEFAULT 'stateless'
  CHECK (session_policy IN ('stateless', 'durable_session'));
