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

/// Parallel assignments one local Worker accepts. Cloud grants and Cloud
/// scheduling can only lower this further.
const defaultLocalWorkerConcurrency = 3;
