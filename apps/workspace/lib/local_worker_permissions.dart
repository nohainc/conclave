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

/// Default total parallel execution slots for the Workspace, shared by all
/// Workers. The user can change it between [minParallelSlots] and
/// [maxParallelSlots].
const defaultLocalWorkerConcurrency = 5;
const minParallelSlots = 1;
const maxParallelSlots = 10;
