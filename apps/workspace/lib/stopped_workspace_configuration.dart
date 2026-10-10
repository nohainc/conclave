import 'dart:io';

import 'work_root.dart';
import 'workspace_lifecycle_store.dart';
import 'workspace_paths.dart';

/// Edits machine-local settings only while no process owns this installation.
/// This is configuration persistence, not an alternative execution runtime.
class StoppedWorkspaceConfiguration {
  const StoppedWorkspaceConfiguration(this.dataDirectory,
      {this.installationId});

  final Directory dataDirectory;
  final String? installationId;

  Future<String> setWorkRoot(String selectedPath) async {
    if (selectedPath.trim().isEmpty) {
      throw const WorkRootViolation('Work Root path must not be empty');
    }
    await dataDirectory.create(recursive: true);
    final paths = WorkspacePaths(dataDirectory);
    final lock = await paths
        .installationLockFile(installationId)
        .open(mode: FileMode.writeOnlyAppend);
    var locked = false;
    try {
      try {
        await lock.lock(FileLock.exclusive);
        locked = true;
      } on FileSystemException {
        throw StateError('Stop the service before changing Work Root.');
      }
      final requested = Directory(selectedPath.trim()).absolute;
      paths.validateWorkRootSeparation(requested);
      final root =
          await WorkRootResolver(overridePath: requested.path).resolve();
      paths.validateWorkRootSeparation(root);
      final preferences = WorkspaceLifecyclePreferencesStore(dataDirectory);
      await preferences
          .write(preferences.readSync().copyWith(workRootPath: root.path));
      return root.path;
    } finally {
      if (locked) await lock.unlock();
      await lock.close();
    }
  }
}
