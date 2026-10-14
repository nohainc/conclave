-- Start fencing for Worker assignments (V9 Phase 3).
--
-- A Service that advertises `assignment.start_permit.v1` must obtain a
-- short-lived start permit from Cloud immediately before it launches the
-- provider process. Cloud grants a permit only while the assignment is still
-- Acknowledged, so once Cloud revokes an assignment no process can start.
--
-- start_permit_required: Cloud told the Service to request a permit (the
--   command carried `startPermit.required`). Zero for older Services, whose
--   revocations still need a Service confirmation.
-- start_permit_issued_at: last time a permit was granted. Non-null means a
--   process may have been launched, so a revocation must wait for the
--   Service to confirm the stop.
ALTER TABLE worker_assignments
  ADD COLUMN start_permit_required INTEGER NOT NULL DEFAULT 0;
ALTER TABLE worker_assignments
  ADD COLUMN start_permit_issued_at TEXT;
