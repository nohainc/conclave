import 'dart:async';
import 'dart:io';

/// A safe, read-only view of a Git remote.
///
/// The URL is reduced to a provider/path display value. Userinfo, query
/// parameters and fragments are never returned because remotes can contain
/// credentials or short-lived tokens.
class WorkstreamRepositoryRemote {
  const WorkstreamRepositoryRemote(
      {required this.name, required this.location});

  final String name;
  final String location;

  Map<String, Object?> toJson() => {'name': name, 'location': location};
}

/// Read-only repository information discovered inside a resolved Workstream
/// directory. [relativePath] is relative to that directory and never an
/// absolute filesystem path.
class WorkstreamRepositoryInfo {
  const WorkstreamRepositoryInfo({
    required this.relativePath,
    required this.remotes,
    required this.branch,
    required this.head,
    required this.dirty,
    required this.changedFileCount,
  });

  final String relativePath;
  final List<WorkstreamRepositoryRemote> remotes;
  final String branch;
  final String head;
  final bool dirty;
  final int changedFileCount;

  Map<String, Object?> toJson() => {
        'relativePath': relativePath,
        'remotes': remotes.map((remote) => remote.toJson()).toList(),
        'branch': branch,
        'head': head,
        'dirty': dirty,
        'changedFileCount': changedFileCount,
      };
}

/// Discovers Git repositories below an already-resolved Workstream directory.
///
/// This service never resolves a Workstream path, creates directories, or
/// changes Git state. Callers must obtain [workstreamDirectory] from the
/// runtime's ID-only Workstream path resolver. A failed or incomplete Git
/// inspection is omitted from the result because observability must not make
/// execution fail.
class WorkstreamRepositoryDiscovery {
  const WorkstreamRepositoryDiscovery({this.gitExecutable = 'git'});

  final String gitExecutable;

  Future<List<WorkstreamRepositoryInfo>> discover(
    Directory workstreamDirectory,
  ) async {
    if (!await workstreamDirectory.exists()) return const [];
    final root = await workstreamDirectory.resolveSymbolicLinks();
    final repositories = <String>[];
    await _findRepositories(Directory(root), repositories);
    repositories.sort();

    final results = <WorkstreamRepositoryInfo>[];
    for (final repositoryPath in repositories) {
      final info = await _inspect(Directory(repositoryPath), root);
      if (info != null) results.add(info);
    }
    return results;
  }

  Future<void> _findRepositories(
    Directory directory,
    List<String> repositories,
  ) async {
    final entries = <FileSystemEntity>[];
    try {
      entries.addAll(await directory.list(followLinks: false).toList());
    } on FileSystemException {
      return;
    }

    var isRepository = false;
    for (final entry in entries) {
      if (entry is! Directory && entry is! File) continue;
      final name = _basename(entry.path);
      if (name != '.git') continue;
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.file) {
        isRepository = true;
      }
    }
    if (isRepository) repositories.add(directory.path);

    for (final entry in entries) {
      if (entry is! Directory || _basename(entry.path) == '.git') continue;
      final type = await FileSystemEntity.type(entry.path, followLinks: false);
      if (type != FileSystemEntityType.directory) continue;
      await _findRepositories(entry, repositories);
    }
  }

  Future<WorkstreamRepositoryInfo?> _inspect(
    Directory repository,
    String root,
  ) async {
    if (!_isContained(repository.path, root)) return null;
    final valid =
        await _run(repository, ['rev-parse', '--is-inside-work-tree']);
    if (valid == null ||
        valid.exitCode != 0 ||
        valid.stdout.toString().trim() != 'true') {
      return null;
    }
    final head = await _run(repository, ['rev-parse', 'HEAD']);
    final branch = await _run(repository, ['branch', '--show-current']);
    final status = await _run(repository, [
      'status',
      '--porcelain=v1',
      '--untracked-files=normal',
    ]);
    final remotes = await _remotes(repository);
    if (head == null || branch == null || status == null) return null;
    if (head.exitCode != 0 || branch.exitCode != 0 || status.exitCode != 0) {
      return null;
    }

    final statusLines = status.stdout
        .toString()
        .split('\n')
        .where((line) => line.trim().isNotEmpty)
        .length;
    return WorkstreamRepositoryInfo(
      relativePath: _relativePath(repository.path, root),
      remotes: remotes,
      branch: branch.stdout.toString().trim().isEmpty
          ? '(detached)'
          : branch.stdout.toString().trim(),
      head: head.stdout.toString().trim(),
      dirty: statusLines > 0,
      changedFileCount: statusLines,
    );
  }

  Future<List<WorkstreamRepositoryRemote>> _remotes(
    Directory repository,
  ) async {
    final names = await _run(repository, ['remote']);
    if (names == null || names.exitCode != 0) return const [];
    final result = <WorkstreamRepositoryRemote>[];
    for (final name in names.stdout
        .toString()
        .split('\n')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)) {
      final urls = await _run(repository, ['remote', 'get-url', '--all', name]);
      if (urls == null || urls.exitCode != 0) continue;
      final locations = urls.stdout
          .toString()
          .split('\n')
          .map(_safeRemoteLocation)
          .where((value) => value != null)
          .cast<String>()
          .toSet();
      for (final location in locations) {
        result.add(WorkstreamRepositoryRemote(name: name, location: location));
      }
    }
    return result;
  }

  Future<ProcessResult?> _run(
    Directory repository,
    List<String> arguments,
  ) async {
    try {
      return await Process.run(
        gitExecutable,
        arguments,
        workingDirectory: repository.path,
        runInShell: false,
      );
    } on ProcessException {
      return null;
    }
  }
}

String? _safeRemoteLocation(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  if (uri != null && uri.host.isNotEmpty) {
    final path = uri.path.isEmpty ? '' : uri.path;
    return '${uri.host}$path';
  }
  final scp = RegExp(r'^[^@/:]+@([^:/]+):(.+)$').firstMatch(value);
  if (scp != null) return '${scp.group(1)}:${scp.group(2)}';
  if (value.startsWith('/') || value.startsWith('file:')) return 'local';
  return 'redacted';
}

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final separator = normalized.lastIndexOf('/');
  return separator < 0 ? normalized : normalized.substring(separator + 1);
}

bool _isContained(String path, String root) {
  final normalizedPath = _normalize(path);
  final normalizedRoot = _normalize(root);
  return normalizedPath == normalizedRoot ||
      normalizedPath.startsWith('$normalizedRoot/');
}

String _relativePath(String path, String root) {
  final normalizedPath = _normalize(path);
  final normalizedRoot = _normalize(root);
  if (normalizedPath == normalizedRoot) return '.';
  return normalizedPath.substring(normalizedRoot.length + 1);
}

String _normalize(String path) =>
    path.replaceAll('\\', '/').replaceFirst(RegExp(r'/$'), '');
