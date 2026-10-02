/// Canonical permissions supported by Workspace assignments.
const executionPermissionIds = <String>{
  'repository:read',
  'repository:write',
  'shell:execute',
  'network:use',
};

/// Local permission ceiling for a newly registered CLI Worker.
const defaultLocalWorkerPermissions = <String>[
  'repository:read',
  'repository:write',
  'shell:execute',
];

const defaultLocalWorkerConcurrency = 1;
