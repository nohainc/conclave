/// Canonical permissions supported by Workspace assignments.
const executionPermissionIds = <String>{
  'repository:read',
  'repository:write',
  'shell:execute',
  'network:use',
};

/// Local permission ceiling for a newly registered CLI Worker. Workers always
/// run with full local access, so this is every execution permission.
const defaultLocalWorkerPermissions = <String>[
  'network:use',
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
