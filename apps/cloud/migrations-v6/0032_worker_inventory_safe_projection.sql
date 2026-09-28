-- V7-12: Cloud inventory retains only safe operational metadata for local
-- Workers. Provider authentication and local execution policy stay on desktop.
UPDATE workspace_worker_inventory
SET name = worker_type_id || ':' || worker_id,
    auth_strategy = 'none',
    default_model = NULL,
    allowed_models_json = '[]',
    local_permissions_summary_json = '[]',
    credential_status = 'not_required';
