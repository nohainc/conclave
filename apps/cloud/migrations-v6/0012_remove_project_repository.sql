-- Repository selection belongs to Workspace Project Grants, not Projects.
-- A Project may span multiple repositories or have none at all.
ALTER TABLE projects DROP COLUMN repository_id;
