-- Correct the execution projection without changing attribution or terminal
-- history. Admission is not provider start; lost/timeouts project as failed.
DROP TRIGGER trg_conversation_turn_assignment_status;
DROP TRIGGER trg_conversation_turn_lifecycle_guard;

-- Repair only demonstrable admission-only Running projections. Unknown older
-- start timestamps are preserved rather than guessed away. Terminal turns are
-- excluded from every repair below.
UPDATE conversation_turns AS ct SET status = 'queued', started_at = NULL
WHERE ct.status = 'running' AND ct.completed_at IS NULL
  AND EXISTS (SELECT 1 FROM worker_assignments wa WHERE wa.id = ct.assignment_id
    AND wa.status IN ('created', 'dispatched', 'acknowledged', 'revocation_pending', 'reconciling')
    AND wa.running_at IS NULL
    AND (ct.started_at IS NULL OR ct.started_at = COALESCE(wa.acknowledged_at, wa.updated_at)));

-- The old trigger retained admission time after provider start. Replace that
-- timestamp only where its admission provenance and later provider evidence
-- are both known. Preserve ambiguous starts and every already-terminal turn.
UPDATE conversation_turns AS ct SET started_at = wa.running_at
FROM worker_assignments wa
WHERE wa.id = ct.assignment_id AND ct.status IN ('queued', 'running')
  AND ct.completed_at IS NULL
  AND ct.started_at = wa.acknowledged_at
  AND julianday(wa.running_at) > julianday(wa.acknowledged_at);

UPDATE conversation_turns AS ct SET
  status = CASE WHEN wa.status IN ('timed_out', 'lost') THEN 'failed' ELSE wa.status END,
  started_at = COALESCE(ct.started_at, wa.running_at,
    CASE WHEN wa.status = 'running' THEN wa.updated_at END),
  completed_at = CASE WHEN wa.status = 'running' THEN NULL ELSE wa.updated_at END,
  result_text = CASE WHEN wa.status = 'completed'
    THEN COALESCE(ct.result_text, json_extract(wa.output_json, '$.output.text')) ELSE ct.result_text END
FROM worker_assignments wa
WHERE wa.id = ct.assignment_id AND ct.status IN ('queued', 'running')
  AND ct.completed_at IS NULL
  AND wa.status IN ('running', 'completed', 'failed', 'cancelled', 'timed_out', 'lost');

CREATE TRIGGER trg_conversation_turn_lifecycle_guard
BEFORE UPDATE ON conversation_turns
WHEN (OLD.status IN ('completed', 'failed', 'cancelled') AND
  (OLD.status IS NOT NEW.status OR OLD.started_at IS NOT NEW.started_at
   OR OLD.completed_at IS NOT NEW.completed_at OR OLD.result_text IS NOT NEW.result_text))
 OR (OLD.status = 'running' AND NEW.status = 'queued')
 OR (OLD.started_at IS NOT NULL AND OLD.started_at IS NOT NEW.started_at)
BEGIN
  SELECT RAISE(ABORT, 'Conversation turn lifecycle cannot regress or rewrite terminal evidence');
END;

CREATE TRIGGER trg_conversation_turn_assignment_status
AFTER UPDATE OF status ON worker_assignments
WHEN OLD.status IS NOT NEW.status
BEGIN
  UPDATE conversation_turns SET
    status = CASE WHEN NEW.status IN ('timed_out', 'lost') THEN 'failed'
      WHEN NEW.status IN ('completed', 'failed', 'cancelled', 'running') THEN NEW.status ELSE status END,
    started_at = COALESCE(started_at, NEW.running_at,
      CASE WHEN NEW.status = 'running' THEN NEW.updated_at END),
    completed_at = CASE WHEN NEW.status IN ('completed', 'failed', 'cancelled', 'timed_out', 'lost')
      THEN NEW.updated_at ELSE completed_at END,
    result_text = CASE WHEN NEW.status = 'completed' THEN json_extract(NEW.output_json, '$.output.text') ELSE result_text END
  WHERE assignment_id = NEW.id AND status IN ('queued', 'running');
END;
