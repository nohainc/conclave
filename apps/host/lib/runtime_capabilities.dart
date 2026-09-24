import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'process_tree.dart';
import 'worker_trust_policy.dart';

class RuntimeViolation implements Exception {
  const RuntimeViolation(this.message);
  final String message;
  @override
  String toString() => 'RuntimeViolation: $message';
}

/// Validates the immutable Project/Workspace scope before a Worker process is
/// launched. Runtime code treats this snapshot as untrusted input even though
/// Cloud produced it, because a Worker must not be able to widen its own scope.
void validateAssignmentScope(
  Map<String, Object?> payload, {
  required Set<String> manifestPermissions,
}) {
  final snapshot = payload['permissionSnapshot'];
  if (snapshot is! Map) {
    throw const RuntimeViolation('assignment permission snapshot is required');
  }
  final scope = snapshot['scope'];
  if (scope is! String ||
      !const {'project_repository', 'selected_paths', 'full_workspace'}
          .contains(scope)) {
    throw const RuntimeViolation('assignment scope is invalid');
  }
  for (final field in [
    'projectId',
    'workspaceId',
    'grantId',
    'requesterUserId'
  ]) {
    final value = snapshot[field];
    if (value is! String || value.trim().isEmpty) {
      throw RuntimeViolation('assignment snapshot field $field is required');
    }
  }
  if (snapshot['projectId'] != payload['projectId'] ||
      snapshot['workspaceId'] != payload['executionWorkspaceId']) {
    throw const RuntimeViolation('assignment scope identity mismatch');
  }
  final permissions = snapshot['permissions'];
  if (permissions is! List || permissions.any((value) => value is! String)) {
    throw const RuntimeViolation(
        'assignment effective permissions are invalid');
  }
  for (final permission in permissions.cast<String>()) {
    if (_isSystemAdministration(permission)) {
      throw RuntimeViolation(
          'system administration is never available to Project assignments: $permission');
    }
    if (!runtimePermissionAllowed(permission, manifestPermissions)) {
      throw RuntimeViolation(
          'assignment permission is not declared by Worker: $permission');
    }
    if (permission == 'network:use' &&
        _networkMode(snapshot['networkPolicy']) == 'deny_all') {
      throw const RuntimeViolation(
          'network permission is denied by Workspace policy');
    }
  }
  _validatePathMappings(snapshot['pathMappings']);
  _rejectWorkerControlledPaths(payload);
  _rejectCredentialMaterial(payload);
}

bool _isSystemAdministration(String permission) => const {
      'system:admin',
      'system:administration',
      'host:admin',
      'process:admin',
    }.contains(permission);

bool runtimePermissionAllowed(String permission, Set<String> manifest) {
  final aliases = <String>{permission};
  if (permission == 'repository:read') {
    aliases.addAll({'workspace:read', 'fs:read'});
  } else if (permission == 'repository:write') {
    aliases.addAll({'workspace:write', 'fs:write'});
  } else if (permission == 'network:use') {
    aliases.addAll({'network:outbound', 'network', 'net:http'});
  } else if (permission == 'shell:execute') {
    aliases.addAll({'shell', 'process:spawn'});
  }
  return aliases.any(manifest.contains);
}

String _networkMode(Object? value) {
  if (value is Map && value['mode'] is String) return value['mode'] as String;
  return 'deny_all';
}

void _validatePathMappings(Object? value) {
  if (value is! List)
    throw const RuntimeViolation('assignment path mappings are invalid');
  for (final mapping in value) {
    if (mapping is! Map ||
        mapping['projectPath'] is! String ||
        mapping['workspacePath'] is! String) {
      throw const RuntimeViolation('assignment path mapping is invalid');
    }
    _validateRelativePath(mapping['projectPath'] as String);
    _validateRelativePath(mapping['workspacePath'] as String);
  }
}

void _rejectWorkerControlledPaths(Map<String, Object?> value) {
  const forbidden = {
    'workingDirectory',
    'working_directory',
    'cwd',
    'workdir',
    'workspacePath'
  };
  void visit(Object? current) {
    if (current is Map) {
      for (final entry in current.entries) {
        if (forbidden.contains(entry.key.toString())) {
          throw const RuntimeViolation(
              'Worker cannot choose an alternate working directory');
        }
        visit(entry.value);
      }
    } else if (current is List) {
      for (final item in current) visit(item);
    }
  }

  visit(value);
}

void _rejectCredentialMaterial(Map<String, Object?> value) {
  const forbidden = {
    'secret',
    'secrets',
    'token',
    'password',
    'apiKey',
    'privateKey'
  };
  void visit(Object? current) {
    if (current is Map) {
      for (final entry in current.entries) {
        final key = entry.key.toString().replaceAll('_', '').toLowerCase();
        if (forbidden.any((part) => key == part.toLowerCase())) {
          throw const RuntimeViolation(
              'Assignment payload contains credential material');
        }
        visit(entry.value);
      }
    } else if (current is List) {
      for (final item in current) visit(item);
    }
  }

  visit(value);
}

void _validateRelativePath(String value) {
  if (value.isEmpty || value.contains('\u0000') || value.contains(':')) {
    throw const RuntimeViolation('assignment path must be relative');
  }
  final segments = value.replaceAll('\\', '/').split('/');
  var depth = 0;
  for (final segment in segments) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (depth == 0)
        throw const RuntimeViolation('assignment path escapes its grant');
      depth -= 1;
    } else {
      depth += 1;
    }
  }
}

class SafeWorkspace {
  SafeWorkspace(Directory root) : root = root.absolute;
  final Directory root;

  String _comparablePath(String value) {
    final normalized = value.replaceAll('/', Platform.pathSeparator);
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  Future<String> _contained(String relative, {bool forWrite = false}) async {
    if (relative.isEmpty || relative.contains('\u0000')) {
      throw const RuntimeViolation('invalid workspace path');
    }
    final lexical = Uri.file(root.path.endsWith(Platform.pathSeparator)
            ? root.path
            : '${root.path}${Platform.pathSeparator}')
        .resolve(relative)
        .toFilePath();
    final lexicalRoot = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    final comparableLexical = _comparablePath(lexical);
    final comparableLexicalRoot = _comparablePath(lexicalRoot);
    final comparableRoot = _comparablePath(root.path);
    if (!comparableLexical.startsWith(comparableLexicalRoot) &&
        comparableLexical != comparableRoot) {
      throw const RuntimeViolation('path escapes workspace root');
    }
    final candidate =
        File('${root.path}${Platform.pathSeparator}$relative').absolute;
    final rootReal = await root.resolveSymbolicLinks();
    final existing = await candidate.exists();
    var parent = candidate.parent;
    while (!await parent.exists() && parent.path != parent.parent.path) {
      parent = parent.parent;
    }
    final resolved = existing
        ? await candidate.resolveSymbolicLinks()
        : await parent.resolveSymbolicLinks();
    final normalizedRoot =
        '${Directory(rootReal).path}${Platform.pathSeparator}';
    final normalized = resolved.endsWith(Platform.pathSeparator)
        ? resolved
        : '$resolved${Platform.pathSeparator}';
    final comparableResolved = _comparablePath(normalized);
    final comparableResolvedRoot = _comparablePath(normalizedRoot);
    if (!comparableResolved.startsWith(comparableResolvedRoot) &&
        _comparablePath(resolved) != _comparablePath(rootReal)) {
      throw const RuntimeViolation('path escapes workspace root');
    }
    if (forWrite) {
      var current = candidate.path;
      while (true) {
        final type = await FileSystemEntity.type(
          current,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) {
          throw const RuntimeViolation(
              'writes through symlinks are not allowed');
        }
        if (current == root.path) break;
        final parent = Directory(current).parent.path;
        if (parent == current) break;
        current = parent;
      }
    }
    return candidate.path;
  }

  Future<String> read(String relative) async {
    final path = await _contained(relative);
    return File(path).readAsString();
  }

  Future<void> write(String relative, String content) async {
    final path = await _contained(relative, forWrite: true);
    await File(path).parent.create(recursive: true);
    await File(path).writeAsString(content, flush: true);
  }

  Future<void> createDirectory(String relative) async {
    final path = await _contained(relative, forWrite: true);
    await Directory(path).create(recursive: true);
  }

  Future<void> patch(
    String relative,
    String oldContent,
    String newContent, {
    int expectedMatches = 1,
  }) async {
    if (expectedMatches <= 0) {
      throw const RuntimeViolation('expected match count must be positive');
    }
    final path = await _contained(relative, forWrite: true);
    final file = File(path);
    final content = await file.readAsString();
    final matches = oldContent.isEmpty
        ? 0
        : RegExp.escape(oldContent).allMatches(content).length;
    if (matches != expectedMatches) {
      throw RuntimeViolation(
        'patch expected $expectedMatches matches but found $matches',
      );
    }
    await file.writeAsString(content.replaceFirst(oldContent, newContent),
        flush: true);
  }

  Future<void> delete(String relative) async {
    final path = await _contained(relative, forWrite: true);
    await File(path).delete();
  }

  Future<String> digest(String relative) async {
    final path = await _contained(relative);
    return sha256.convert(await File(path).readAsBytes()).toString();
  }

  Future<List<String>> search(
    String query, {
    String relativeRoot = '.',
    int maxResults = 100,
    int maxFileBytes = 1024 * 1024,
    Set<String> ignoredDirectories = const {
      '.git',
      '.dart_tool',
      'node_modules'
    },
  }) async {
    if (query.isEmpty || maxResults <= 0 || maxFileBytes <= 0) {
      throw const RuntimeViolation('invalid search options');
    }
    final rootPath = await _contained(relativeRoot);
    final searchRoot = Directory(rootPath);
    if (!await searchRoot.exists()) {
      throw const RuntimeViolation('search root does not exist');
    }
    final matches = <String>[];
    await for (final entity
        in searchRoot.list(recursive: true, followLinks: false)) {
      if (matches.length >= maxResults) break;
      if (entity is! File || await entity.length() > maxFileBytes) continue;
      final relative = _relativePath(entity.path);
      if (relative.split(RegExp(r'[/\\]')).any(ignoredDirectories.contains)) {
        continue;
      }
      try {
        await _contained(relative);
        if ((await entity.readAsString()).contains(query)) {
          matches.add(relative);
        }
      } on FormatException {
        // Binary files are not text search candidates.
      }
    }
    return matches;
  }

  String _relativePath(String absolutePath) {
    final rootPath = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    final normalizedAbsolute =
        absolutePath.replaceAll('/', Platform.pathSeparator);
    if (!_comparablePath(normalizedAbsolute)
        .startsWith(_comparablePath(rootPath))) {
      throw const RuntimeViolation('path escapes workspace root');
    }
    final relative = normalizedAbsolute
        .substring(rootPath.length)
        .replaceFirst('.${Platform.pathSeparator}', '');
    // Repository-relative paths are protocol/evidence values, not native
    // filesystem paths. Keep them stable across Windows/macOS/Linux.
    return relative.replaceAll('\\', '/');
  }
}

class CommandPolicy {
  const CommandPolicy(
      {required this.allowedExecutables,
      this.allowedArgumentPatterns = const {},
      this.secretValues = const {},
      this.maxOutputBytes = 256 * 1024,
      this.timeout = const Duration(minutes: 2)});
  final Set<String> allowedExecutables;

  /// Optional per-executable argument allowlists. When configured, every
  /// argument must match at least one pattern for that executable.
  final Map<String, List<RegExp>> allowedArgumentPatterns;
  final Set<String> secretValues;
  final int maxOutputBytes;
  final Duration timeout;
}

class CommandResult {
  const CommandResult(
      {required this.exitCode,
      required this.stdout,
      required this.stderr,
      required this.timedOut});
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

class SafeCommandRunner {
  SafeCommandRunner(this.workspace);
  final SafeWorkspace workspace;

  Future<CommandResult> run(List<String> command,
      {required CommandPolicy policy, String workingDirectory = '.'}) async {
    if (command.isEmpty || !policy.allowedExecutables.contains(command.first)) {
      throw const RuntimeViolation('command is not allowlisted');
    }
    if (policy.maxOutputBytes <= 0) {
      throw const RuntimeViolation('output limit must be positive');
    }
    if (command.skip(1).any((argument) =>
        argument.isEmpty ||
        argument.contains('\u0000') ||
        RegExp(r'[;&|<>`\$()]').hasMatch(argument))) {
      throw const RuntimeViolation('command argument contains shell syntax');
    }
    final patterns = policy.allowedArgumentPatterns[command.first];
    if (patterns != null &&
        command.skip(1).any((argument) =>
            !patterns.any((pattern) => pattern.hasMatch(argument)))) {
      throw const RuntimeViolation('command argument is not allowlisted');
    }
    final cwd = Directory(await workspace._contained(workingDirectory));
    final process = await startIsolatedProcess(
      command.first,
      command.skip(1).toList(),
      workingDirectory: cwd.path,
      environment: {'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin'},
    );
    var outputLimitExceeded = false;
    Future<void> stopForOutputLimit() async {
      if (outputLimitExceeded) return;
      outputLimitExceeded = true;
      await terminateProcessTree(process, force: true);
    }

    final stdoutFuture =
        _bounded(process.stdout, policy.maxOutputBytes, stopForOutputLimit);
    final stderrFuture =
        _bounded(process.stderr, policy.maxOutputBytes, stopForOutputLimit);
    var timedOut = false;
    final exit = process.exitCode.timeout(policy.timeout, onTimeout: () {
      timedOut = true;
      unawaited(terminateProcessTree(process, force: true));
      return -1;
    });
    return CommandResult(
      exitCode: await exit,
      stdout: redactSecrets(await stdoutFuture, policy.secretValues),
      stderr: redactSecrets(await stderrFuture, policy.secretValues),
      timedOut: timedOut,
    );
  }

  Future<String> _bounded(Stream<List<int>> stream, int maxBytes,
      Future<void> Function() onExceeded) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length + chunk.length > maxBytes) {
        bytes.addAll(chunk.take(maxBytes - bytes.length));
        await onExceeded();
        break;
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class GitRepository {
  GitRepository(this.workspace, {this.gitExecutable = 'git'});

  final SafeWorkspace workspace;
  final String gitExecutable;

  Future<void> validate() async {
    final result = await _run(['rev-parse', '--is-inside-work-tree']);
    if (result.exitCode != 0 || result.stdout.trim() != 'true') {
      throw const RuntimeViolation('workspace is not a Git repository');
    }
  }

  Future<CommandResult> status() => _run(['status', '--short']);

  Future<CommandResult> diff() => _run(['diff', '--no-ext-diff']);

  Future<String> currentRevision() async {
    final result = await _run(['rev-parse', 'HEAD']);
    if (result.exitCode != 0) {
      throw const RuntimeViolation('could not resolve Git revision');
    }
    return result.stdout.trim();
  }

  Future<String> branch() async {
    final result = await _run(['branch', '--show-current']);
    if (result.exitCode != 0) {
      throw const RuntimeViolation('could not resolve Git branch');
    }
    return result.stdout.trim();
  }

  /// Creates a detached Git worktree below the registered workspace root.
  ///
  /// The path is always passed to Git as a workspace-relative path. This
  /// keeps parallel worker checkouts inside the approved repository even when
  /// a caller supplies a path containing traversal components.
  Future<void> createWorktree(String relativePath, {String? revision}) async {
    final path = await workspace._contained(relativePath, forWrite: true);
    if (await Directory(path).exists() || await File(path).exists()) {
      throw const RuntimeViolation('worktree path already exists');
    }
    final arguments = <String>['worktree', 'add', '--detach', relativePath];
    if (revision != null) {
      if (revision.isEmpty ||
          revision.contains(RegExp(r'[^A-Za-z0-9_./:@=-]'))) {
        throw const RuntimeViolation('invalid Git revision');
      }
      arguments.add(revision);
    }
    final result = await _run(arguments);
    if (result.exitCode != 0) {
      throw RuntimeViolation(
        'could not create Git worktree: ${result.stderr.trim()}',
      );
    }
  }

  /// Removes a worktree below the registered workspace root.
  Future<void> removeWorktree(String relativePath, {bool force = false}) async {
    await workspace._contained(relativePath, forWrite: true);
    final arguments = <String>['worktree', 'remove'];
    if (force) arguments.add('--force');
    arguments.add(relativePath);
    final result = await _run(arguments);
    if (result.exitCode != 0) {
      throw RuntimeViolation(
        'could not remove Git worktree: ${result.stderr.trim()}',
      );
    }
  }

  Future<CommandResult> _run(List<String> arguments) =>
      SafeCommandRunner(workspace).run([gitExecutable, ...arguments],
          policy: CommandPolicy(
            allowedExecutables: {gitExecutable},
            allowedArgumentPatterns: {
              gitExecutable: [RegExp(r'^[A-Za-z0-9_./:@=-]+$')],
            },
          ));
}

class RuntimeArtifact {
  const RuntimeArtifact(
      {required this.path, required this.sizeBytes, required this.sha256});
  final String path;
  final int sizeBytes;
  final String sha256;
}

Future<RuntimeArtifact> stageArtifact(
  File file, {
  int maxBytes = 64 * 1024 * 1024,
}) async {
  if (maxBytes <= 0) {
    throw const RuntimeViolation('artifact size limit must be positive');
  }
  final size = await file.length();
  if (size > maxBytes) {
    throw RuntimeViolation(
      'artifact exceeds the $maxBytes byte staging limit',
    );
  }
  final digest = sha256.convert(await file.readAsBytes());
  return RuntimeArtifact(
      path: file.path, sizeBytes: size, sha256: digest.toString());
}
