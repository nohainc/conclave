/// Local permissions granted to the first-party Worker Packages by default.
/// This is Workspace policy, not provider or package identity metadata.
const firstPartyWorkerLocalPermissions = <String>[
  'workstream_filesystem',
  'shell_execution',
];

const defaultLocalWorkerConcurrency = 1;
