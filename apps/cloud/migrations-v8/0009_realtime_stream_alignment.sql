-- Align production realtime event tables with the stream-aware v8 contract.
-- Preserves all historical workspace-scoped event cursors and events.

CREATE TABLE __migration_0009_realtime_counts (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  cursors_before INTEGER NOT NULL,
  events_before INTEGER NOT NULL
);

INSERT INTO __migration_0009_realtime_counts (
  singleton,
  cursors_before,
  events_before
)
VALUES (
  1,
  (SELECT COUNT(*) FROM realtime_event_cursors),
  (SELECT COUNT(*) FROM realtime_events)
);

CREATE TABLE realtime_event_cursors__stream_aligned (
  stream_kind TEXT NOT NULL DEFAULT 'execution_workspace' CHECK (stream_kind IN ('execution_workspace', 'space', 'user')),
  stream_id TEXT,
  workspace_id TEXT,
  next_sequence INTEGER NOT NULL DEFAULT 0,
  CHECK (COALESCE(stream_id, workspace_id) IS NOT NULL)
);

INSERT INTO realtime_event_cursors__stream_aligned (
  stream_kind,
  stream_id,
  workspace_id,
  next_sequence
)
SELECT
  'execution_workspace',
  workspace_id,
  workspace_id,
  next_sequence
FROM realtime_event_cursors;

DROP TABLE realtime_event_cursors;
ALTER TABLE realtime_event_cursors__stream_aligned RENAME TO realtime_event_cursors;

CREATE UNIQUE INDEX idx_realtime_event_cursors_stream
  ON realtime_event_cursors(stream_kind, COALESCE(stream_id, workspace_id));

CREATE TABLE realtime_events__stream_aligned (
  event_id TEXT PRIMARY KEY,
  stream_kind TEXT NOT NULL DEFAULT 'execution_workspace' CHECK (stream_kind IN ('execution_workspace', 'space', 'user')),
  stream_id TEXT,
  workspace_id TEXT,
  thread_id TEXT,
  space_id TEXT,
  run_id TEXT,
  task_id TEXT,
  attempt_id TEXT,
  assignment_id TEXT,
  workspace_runtime_id TEXT,
  sequence INTEGER NOT NULL,
  event_type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  idempotency_key TEXT NOT NULL,
  occurred_at TEXT NOT NULL,
  CHECK (COALESCE(stream_id, workspace_id) IS NOT NULL),
  CHECK ((stream_kind = 'execution_workspace' AND workspace_id IS NOT NULL AND (stream_id IS NULL OR stream_id = workspace_id)) OR
         (stream_kind <> 'execution_workspace' AND workspace_id IS NULL AND stream_id IS NOT NULL))
);

INSERT INTO realtime_events__stream_aligned (
  event_id,
  stream_kind,
  stream_id,
  workspace_id,
  thread_id,
  space_id,
  run_id,
  task_id,
  attempt_id,
  assignment_id,
  workspace_runtime_id,
  sequence,
  event_type,
  payload_json,
  idempotency_key,
  occurred_at
)
SELECT
  event_id,
  'execution_workspace',
  workspace_id,
  workspace_id,
  NULL,
  space_id,
  run_id,
  task_id,
  attempt_id,
  assignment_id,
  workspace_runtime_id,
  sequence,
  event_type,
  payload_json,
  idempotency_key,
  occurred_at
FROM realtime_events;

DROP TABLE realtime_events;
ALTER TABLE realtime_events__stream_aligned RENAME TO realtime_events;

CREATE UNIQUE INDEX idx_realtime_events_stream_seq
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), sequence);

CREATE UNIQUE INDEX idx_realtime_events_stream_idempotency
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), idempotency_key);

CREATE INDEX idx_realtime_events_workspace_time
  ON realtime_events(workspace_id, occurred_at);

CREATE INDEX idx_realtime_events_stream_time
  ON realtime_events(stream_kind, COALESCE(stream_id, workspace_id), occurred_at);

CREATE TABLE __migration_0009_realtime_count_assertion (
  counts_match INTEGER NOT NULL CHECK (counts_match = 1)
);

INSERT INTO __migration_0009_realtime_count_assertion (counts_match)
SELECT CASE
  WHEN cursors_before = (SELECT COUNT(*) FROM realtime_event_cursors)
   AND events_before = (SELECT COUNT(*) FROM realtime_events)
  THEN 1
  ELSE 0
END
FROM __migration_0009_realtime_counts;

DROP TABLE __migration_0009_realtime_count_assertion;
DROP TABLE __migration_0009_realtime_counts;
