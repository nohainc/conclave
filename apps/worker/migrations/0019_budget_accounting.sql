ALTER TABLE budgets ADD COLUMN run_id TEXT REFERENCES runs(id) ON DELETE CASCADE;
ALTER TABLE budgets ADD COLUMN max_input_tokens INTEGER;
ALTER TABLE budgets ADD COLUMN max_output_tokens INTEGER;
ALTER TABLE budgets ADD COLUMN used_input_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE budgets ADD COLUMN used_output_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE budgets ADD COLUMN used_cost_micros INTEGER NOT NULL DEFAULT 0;
ALTER TABLE budgets ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
CREATE INDEX idx_budgets_run ON budgets(run_id);
