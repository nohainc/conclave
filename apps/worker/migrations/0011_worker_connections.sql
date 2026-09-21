-- W1: keep worker identity separate from transport, authentication, and billing.
CREATE TABLE connections (
  id TEXT PRIMARY KEY,
  organization_id TEXT NOT NULL REFERENCES organizations(id),
  name TEXT NOT NULL,
  transport TEXT NOT NULL CHECK (transport IN ('provider_api', 'local_agent', 'remote_agent', 'local_model', 'web_app', 'manual')),
  provider TEXT,
  adapter_version TEXT NOT NULL,
  auth_mode TEXT NOT NULL CHECK (auth_mode IN ('api_key', 'subscription_session', 'oauth', 'service_identity', 'local_session', 'none', 'manual')),
  billing_mode TEXT NOT NULL CHECK (billing_mode IN ('api_metered', 'subscription', 'local_compute', 'external', 'manual')),
  cost_metadata_json TEXT NOT NULL DEFAULT '{}',
  execution_environment TEXT NOT NULL CHECK (execution_environment IN ('cloud', 'local', 'ci', 'human')),
  availability TEXT NOT NULL DEFAULT 'available' CHECK (availability IN ('available', 'busy', 'disabled', 'offline')),
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE worker_connections (
  worker_id TEXT NOT NULL REFERENCES workers(id),
  connection_id TEXT NOT NULL REFERENCES connections(id),
  is_default INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL,
  PRIMARY KEY (worker_id, connection_id)
);

CREATE INDEX idx_connections_organization ON connections(organization_id);
CREATE INDEX idx_worker_connections_connection ON worker_connections(connection_id);
