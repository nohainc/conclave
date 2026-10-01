-- Architecture v8 resolves local CLI integrations through the signed Tool
-- Profile registry and the generic Engine. Native provider Worker packages
-- are migration-only and must not exist in a clean or upgraded v8 database.
DROP TABLE IF EXISTS worker_releases;
