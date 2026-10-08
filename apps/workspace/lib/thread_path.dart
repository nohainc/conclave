import 'dart:io';

/// Pure ID-only Thread path resolver.
///
/// It does not accept display names, user identity, Workspace identity, or a
/// caller-provided relative path. It also does not create the directory; that
/// belongs to the later lazy lifecycle phase.
class ThreadPathResolver {
  ThreadPathResolver(Directory workRoot)
      : _workRoot = Directory(workRoot.absolute.path);

  final Directory _workRoot;

  /// Resolves the logical Thread directory beneath the Work Root.
  ///
  /// If an existing Space or Thread directory contains a symlink, the
  /// resolved target must remain within the canonical Work Root. A missing
  /// target is returned as a deterministic, non-created path.
  Future<Directory> resolve({
    required String spaceId,
    required String threadId,
  }) async {
    _validateId(spaceId, 'spaceId');
    _validateId(threadId, 'threadId');

    final root = await _canonicalRoot();
    final spacePath = _join(root.path, spaceId);
    final space = await _resolveExistingOrLexical(
      Directory(spacePath),
      root,
      'Space directory',
    );
    final threadPath = _join(space.path, threadId);
    return _resolveExistingOrLexical(
      Directory(threadPath),
      root,
      'Thread directory',
    );
  }

  Future<Directory> _canonicalRoot() async {
    final type = await FileSystemEntity.type(_workRoot.path, followLinks: true);
    if (type != FileSystemEntityType.directory) {
      throw const ThreadPathViolation('Work Root must be a directory');
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
      throw ThreadPathViolation('$label is not a directory');
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
      throw ThreadPathViolation('$label escapes the Work Root');
    }
  }

  void _validateId(String value, String field) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value)) {
      throw ThreadPathViolation(
          '$field must be a safe immutable Cloud ID path component');
    }
    if (value == '.' || value == '..') {
      throw ThreadPathViolation('$field cannot be a dot path component');
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

class ThreadPathViolation implements Exception {
  const ThreadPathViolation(this.message);

  final String message;

  @override
  String toString() => 'ThreadPathViolation: $message';
}
