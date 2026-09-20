ALTER TABLE workers ADD COLUMN provider TEXT NOT NULL DEFAULT 'unknown';
ALTER TABLE workers ADD COLUMN availability TEXT NOT NULL DEFAULT 'available';
ALTER TABLE workers ADD COLUMN execution_environment TEXT NOT NULL DEFAULT 'cloud';
ALTER TABLE workers ADD COLUMN cost_metadata_json TEXT NOT NULL DEFAULT '{}';

CREATE INDEX idx_workers_availability ON workers(availability);
CREATE INDEX idx_workers_provider ON workers(provider);
