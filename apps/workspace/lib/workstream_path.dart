import 'dart:io';

/// WD-2 pure ID-only Workstream path resolver.
///
/// It does not accept display names, user identity, Workspace identity, or a
/// caller-provided relative path. It also does not create the directory; that
/// belongs to the later lazy lifecycle phase.
class WorkstreamPathResolver {
  WorkstreamPathResolver(Directory workRoot)
      : _workRoot = Directory(workRoot.absolute.path);

  final Directory _workRoot;

  /// Resolves the logical Workstream directory beneath the Work Root.
  ///
  /// If an existing project or Workstream directory contains a symlink, the
  /// resolved target must remain within the canonical Work Root. A missing
  /// target is returned as a deterministic, non-created path.
  Future<Directory> resolve({
    required String projectId,
    required String workstreamId,
  }) async {
    _validateId(projectId, 'projectId');
    _validateId(workstreamId, 'workstreamId');

    final root = await _canonicalRoot();
    final projectPath = _join(root.path, projectId);
    final project = await _resolveExistingOrLexical(
      Directory(projectPath),
      root,
      'Project directory',
    );
    final workstreamPath = _join(project.path, workstreamId);
    return _resolveExistingOrLexical(
      Directory(workstreamPath),
      root,
      'Workstream directory',
    );
  }

  Future<Directory> _canonicalRoot() async {
    final type = await FileSystemEntity.type(_workRoot.path, followLinks: true);
    if (type != FileSystemEntityType.directory) {
      throw const WorkstreamPathViolation('Work Root must be a directory');
    }
    final root = Directory(await _workRoot.resolveSymbolicLinks());
    return root;
  }

  Future<Directory> _resolveExistingOrLexical(
    Directory requested,
    Directory root,
    String label,
  ) async {
    final type =
        await FileSystemEntity.type(requested.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      _assertContained(requested.path, root.path, label);
      return requested;
    }
    if (type != FileSystemEntityType.directory) {
      throw WorkstreamPathViolation('$label is not a directory');
    }
    final resolved = Directory(await requested.resolveSymbolicLinks());
    _assertContained(resolved.path, root.path, label);
    return resolved;
  }

  void _assertContained(String path, String root, String label) {
    final normalizedRoot = _normalize(root);
    final normalizedPath = _normalize(path);
    if (normalizedPath == normalizedRoot ||
        !normalizedPath
            .startsWith('$normalizedRoot${Platform.pathSeparator}')) {
      throw WorkstreamPathViolation('$label escapes the Work Root');
    }
  }

  void _validateId(String value, String field) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value)) {
      throw WorkstreamPathViolation(
          '$field must be a safe immutable Cloud ID path component');
    }
    if (value == '.' || value == '..') {
      throw WorkstreamPathViolation('$field cannot be a dot path component');
    }
  }

  String _join(String parent, String child) =>
      '$parent${Platform.pathSeparator}$child';

  String _normalize(String value) {
    final normalized = Directory(value).absolute.path;
    return normalized.endsWith(Platform.pathSeparator) && normalized.length > 1
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
  }
}

class WorkstreamPathViolation implements Exception {
  const WorkstreamPathViolation(this.message);

  final String message;

  @override
  String toString() => 'WorkstreamPathViolation: $message';
}
