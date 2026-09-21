-- W2: persist the exact connection selected for each execution.
ALTER TABLE model_calls ADD COLUMN connection_id TEXT REFERENCES connections(id);

CREATE INDEX idx_model_calls_connection ON model_calls(connection_id);
