-- Project settings are optional collaboration metadata. Keep this as a
-- forward migration because 0001_conclave_v6.sql may already be applied.
ALTER TABLE projects ADD COLUMN settings_json TEXT NOT NULL DEFAULT '{}';
