-- EW-7: Workstream execution policy narrows Worker eligibility without
-- introducing Account-first product concepts.
ALTER TABLE workstream_execution_policies
  ADD COLUMN allowed_configured_worker_ids_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE workstream_execution_policies
  ADD COLUMN allowed_worker_type_ids_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE workstream_execution_policies
  ADD COLUMN allowed_providers_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE workstream_execution_policies
  ADD COLUMN allowed_models_json TEXT NOT NULL DEFAULT '[]';

ALTER TABLE workstream_execution_policies
  ADD COLUMN budget_json TEXT;
