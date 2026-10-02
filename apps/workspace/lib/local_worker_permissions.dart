/// Local permissions granted to the first-party Worker Packages by default.
/// This is Workspace policy, not provider or package identity metadata.
const firstPartyWorkerLocalPermissions = <String>[
  'workstream_filesystem',
  'shell_execution',
];

const defaultLocalWorkerConcurrency = 1;

/// Maps catalog capabilities to Workspace-enforced access. Provider process
/// launch stays an Engine responsibility and does not grant a general shell.
List<String> permissionsForLogicalWorker(Iterable<String> capabilities) {
  final values = capabilities.toSet();
  if (values.contains('local_file') ||
      values.contains('workstream_read') ||
      values.contains('workstream_write')) {
    return const ['workstream_filesystem'];
  }
  return const [];
}
