CREATE TABLE IF NOT EXISTS completion_criteria (
  id TEXT PRIMARY KEY,
  goal_id TEXT NOT NULL REFERENCES goals(id),
  description TEXT NOT NULL,
  verification_requirement TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('pending', 'verified', 'failed', 'waived')),
  evidence_artifact_ids_json TEXT NOT NULL,
  verified_by_worker_id TEXT,
  verification_id TEXT,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  UNIQUE (goal_id, id)
);

CREATE INDEX IF NOT EXISTS idx_completion_criteria_goal_id
  ON completion_criteria(goal_id);
