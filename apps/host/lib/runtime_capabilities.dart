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

/// Rejects Cloud/Worker payloads that attempt to choose a process CWD.
///
/// The Host must resolve the Workstream directory locally from immutable IDs.
void rejectWorkerControlledPaths(Map<String, Object?> value) {
  _rejectWorkerControlledPaths(value);
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

  Future<String> resolveRevision(String revision) async {
    _validateGitValue(revision, 'revision');
    final result = await _run(['rev-parse', '--verify', revision]);
    if (result.exitCode != 0) {
      throw const RuntimeViolation('could not verify Git revision');
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

  Future<void> createBranchWorktree(
    String relativePath, {
    required String branch,
    String revision = 'HEAD',
  }) async {
    await workspace._contained(relativePath, forWrite: true);
    _validateGitValue(branch, 'branch');
    _validateGitValue(revision, 'revision');
    final result =
        await _run(['worktree', 'add', '-b', branch, relativePath, revision]);
    if (result.exitCode != 0) {
      throw RuntimeViolation(
        'could not create Git branch worktree: ${result.stderr.trim()}',
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

  Future<void> resetHard(String revision) async {
    _validateGitValue(revision, 'revision');
    final result = await _run(['reset', '--hard', revision]);
    if (result.exitCode != 0) {
      throw RuntimeViolation(
          'could not reset Git worktree: ${result.stderr.trim()}');
    }
    final clean = await _run(['clean', '-fd']);
    if (clean.exitCode != 0) {
      throw RuntimeViolation(
          'could not clean Git worktree: ${clean.stderr.trim()}');
    }
  }

  Future<String> checkpointCommit(String message) async {
    if (message.trim().isEmpty || message.contains('\u0000')) {
      throw const RuntimeViolation('checkpoint message is required');
    }
    final add = await _run(['add', '-A']);
    if (add.exitCode != 0) {
      throw RuntimeViolation(
          'could not stage checkpoint: ${add.stderr.trim()}');
    }
    final commit = await _run(
      ['commit', '-m', message],
      argumentPattern: RegExp(r'^[A-Za-z0-9_./:@= -]+$'),
    );
    if (commit.exitCode != 0) {
      throw RuntimeViolation(
          'could not create checkpoint commit: ${commit.stderr.trim()}');
    }
    return currentRevision();
  }

  Future<CommandResult> _run(
    List<String> arguments, {
    RegExp? argumentPattern,
  }) =>
      SafeCommandRunner(workspace).run([gitExecutable, ...arguments],
          policy: CommandPolicy(
            allowedExecutables: {gitExecutable},
            allowedArgumentPatterns: {
              gitExecutable: [
                argumentPattern ?? RegExp(r'^[A-Za-z0-9_./:@=-]+$'),
              ],
            },
          ));
}

void _validateGitValue(String value, String field) {
  if (value.isEmpty || value.contains(RegExp(r'[^A-Za-z0-9_./:@=-]'))) {
    throw RuntimeViolation('invalid Git $field');
  }
}

/// @deprecated Historical compatibility model. Active execution uses the
/// ID-derived Workstream directory and mutation coordinator.
@Deprecated('Use the Workstream directory lifecycle instead')
class WorkstreamCheckout {
  const WorkstreamCheckout({
    required this.id,
    required this.workstreamId,
    required this.relativePath,
    required this.branch,
    required this.revision,
    required this.archived,
  });

  final String id;
  final String workstreamId;
  final String relativePath;
  final String branch;
  final String revision;
  final bool archived;
}

class WorkstreamCheckoutStatus {
  const WorkstreamCheckoutStatus({
    required this.checkout,
    required this.currentRevision,
    required this.currentBranch,
    required this.dirty,
    required this.status,
    required this.diff,
  });

  final WorkstreamCheckout checkout;
  final String currentRevision;
  final String currentBranch;
  final bool dirty;
  final String status;
  final String diff;
}

class WorkstreamCheckoutLifecycleResult {
  const WorkstreamCheckoutLifecycleResult({
    required this.outcome,
    required this.revision,
    required this.changed,
    required this.diff,
    this.recoveryStatus,
  });

  final String outcome;
  final String revision;
  final bool changed;
  final String diff;
  final String? recoveryStatus;
}

/// @deprecated Historical checkout control plane retained for compatibility
/// fixtures. Active assignments use the ID-derived Workstream directory.
@Deprecated('Use WorkstreamDirectoryLifecycle and WorkstreamMutationCoordinator')
class WorkstreamCheckoutManager {
  WorkstreamCheckoutManager(Directory repositoryRoot)
      : _repositoryRoot = SafeWorkspace(repositoryRoot),
        _repository = GitRepository(SafeWorkspace(repositoryRoot));

  final SafeWorkspace _repositoryRoot;
  final GitRepository _repository;
  final Map<String, Future<void>> _localLocks = {};

  String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

  String _metadataRelativePath(String checkoutId) =>
      '.conclave/checkout-metadata/${_hash(checkoutId)}.json';

  String _checkoutRelativePath(String workstreamId, String checkoutId) =>
      '.conclave/workstreams/${_hash(workstreamId)}/${_hash(checkoutId)}';

  String _lockRelativePath(String checkoutId) =>
      '.conclave/checkout-locks/${_hash(checkoutId)}.lock';

  String _fenceRelativePath(String checkoutId) =>
      '.conclave/checkout-fences/${_hash(checkoutId)}.json';

  void _validateOpaqueId(String value, String field) {
    if (value.isEmpty ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$').hasMatch(value)) {
      throw RuntimeViolation('$field must be an opaque identifier');
    }
  }

  Future<WorkstreamCheckout> provision({
    required String checkoutId,
    required String workstreamId,
    String revision = 'HEAD',
  }) async {
    _validateOpaqueId(checkoutId, 'checkoutId');
    _validateOpaqueId(workstreamId, 'workstreamId');
    return _withFileLock(checkoutId, () async {
      final existing = await _read(checkoutId);
      if (existing != null) {
        if (existing.workstreamId != workstreamId || existing.archived) {
          throw const RuntimeViolation('checkout ID is already assigned');
        }
        await _verify(existing);
        return existing;
      }
      await _repositoryRoot.createDirectory('.conclave/checkout-metadata');
      await _repositoryRoot.createDirectory('.conclave/checkout-locks');
      final relativePath = _checkoutRelativePath(workstreamId, checkoutId);
      final branch =
          'conclave/workstream/${_hash(checkoutId).substring(0, 16)}';
      final checkoutPath = await _repositoryRoot._contained(relativePath);
      if (await Directory(checkoutPath).exists()) {
        final orphan = WorkstreamCheckout(
          id: checkoutId,
          workstreamId: workstreamId,
          relativePath: relativePath,
          branch: branch,
          revision: revision,
          archived: false,
        );
        await _verify(orphan);
      } else {
        await _repository.createBranchWorktree(
          relativePath,
          branch: branch,
          revision: revision,
        );
      }
      final checkout = WorkstreamCheckout(
        id: checkoutId,
        workstreamId: workstreamId,
        relativePath: relativePath,
        branch: branch,
        revision: revision,
        archived: false,
      );
      await _write(checkout);
      return checkout;
    });
  }

  Future<WorkstreamCheckout?> _read(String checkoutId) async {
    _validateOpaqueId(checkoutId, 'checkoutId');
    try {
      final raw = jsonDecode(
          await _repositoryRoot.read(_metadataRelativePath(checkoutId)));
      if (raw is! Map) throw const FormatException('metadata is not an object');
      return WorkstreamCheckout(
        id: raw['id'] as String,
        workstreamId: raw['workstreamId'] as String,
        relativePath: raw['relativePath'] as String,
        branch: raw['branch'] as String,
        revision: raw['revision'] as String,
        archived: raw['archived'] == true,
      );
    } on PathNotFoundException {
      return null;
    } on FileSystemException {
      return null;
    } on FormatException catch (error) {
      throw RuntimeViolation('checkout metadata is invalid: $error');
    }
  }

  Future<WorkstreamCheckout> resolve(String checkoutId) async {
    final checkout = await _read(checkoutId);
    if (checkout == null || checkout.archived) {
      throw const RuntimeViolation('checkout is not available');
    }
    await _verify(checkout);
    return checkout;
  }

  Future<void> _verify(WorkstreamCheckout checkout) async {
    await _repositoryRoot._contained(checkout.relativePath);
    final repo = GitRepository(
      SafeWorkspace(Directory(
          '${_repositoryRoot.root.path}${Platform.pathSeparator}${checkout.relativePath}')),
    );
    await repo.validate();
    if (await repo.branch() != checkout.branch) {
      throw const RuntimeViolation('checkout branch does not match metadata');
    }
    await repo.resolveRevision(checkout.revision);
  }

  Future<WorkstreamCheckoutStatus> status(String checkoutId) async {
    final checkout = await resolve(checkoutId);
    return _statusForCheckout(checkout);
  }

  Future<WorkstreamCheckoutStatus> _statusForCheckout(
      WorkstreamCheckout checkout) async {
    final repo = _repoFor(checkout);
    final status = await repo.status();
    final diff = await repo.diff();
    return WorkstreamCheckoutStatus(
      checkout: checkout,
      currentRevision: await repo.currentRevision(),
      currentBranch: await repo.branch(),
      dirty: status.stdout.trim().isNotEmpty,
      status: status.stdout,
      diff: diff.stdout,
    );
  }

  /// Validates a stateful Assignment snapshot and holds the OS lock for the
  /// complete Worker lifetime. The fence is persisted per checkout so a
  /// restarted process cannot accept an older lease token.
  Future<T> withStatefulLease<T>({
    required Map<String, Object?> snapshot,
    required Future<T> Function(WorkstreamCheckout checkout) action,
  }) async {
    final executionClass = snapshot['executionClass'];
    if (executionClass != 'stateful_workstream') {
      throw const RuntimeViolation('stateful execution class is required');
    }
    String requiredField(String name) {
      final value = snapshot[name];
      if (value is! String || value.isEmpty) {
        throw RuntimeViolation('stateful assignment field $name is required');
      }
      return value;
    }

    final workstreamId = requiredField('workstreamId');
    final checkoutId = requiredField('checkoutId');
    final leaseId = requiredField('leaseId');
    final expectedRevision = requiredField('expectedRevision');
    final rawToken = snapshot['fencingToken'];
    if (rawToken is! int || rawToken <= 0) {
      throw const RuntimeViolation(
          'stateful assignment fencingToken is invalid');
    }
    return _withFileLock(checkoutId, () async {
      final checkout = await resolve(checkoutId);
      if (checkout.workstreamId != workstreamId) {
        throw const RuntimeViolation(
            'assignment checkout does not belong to Workstream');
      }
      final checkoutStatus = await _statusForCheckout(checkout);
      if (checkoutStatus.currentRevision != expectedRevision) {
        throw RuntimeViolation(
            'checkout revision mismatch: expected $expectedRevision, found ${checkoutStatus.currentRevision}');
      }
      if (checkoutStatus.dirty) {
        throw const RuntimeViolation('stateful checkout must be clean');
      }
      final previous = await _readFence(checkoutId);
      if (previous != null) {
        final previousToken = previous['fencingToken'];
        final previousLease = previous['leaseId'];
        if (previousToken is! int ||
            rawToken < previousToken ||
            (rawToken == previousToken && previousLease != leaseId)) {
          throw const RuntimeViolation(
              'stale or conflicting checkout fencing token');
        }
      }
      await _writeFence(checkoutId, leaseId, rawToken);
      return action(checkout);
    });
  }

  Future<Map<String, Object?>?> _readFence(String checkoutId) async {
    try {
      final raw = jsonDecode(
          await _repositoryRoot.read(_fenceRelativePath(checkoutId)));
      if (raw is! Map) return null;
      return Map<String, Object?>.from(raw);
    } on PathNotFoundException {
      return null;
    } on FileSystemException {
      return null;
    } on FormatException {
      throw const RuntimeViolation('checkout fencing metadata is invalid');
    }
  }

  Future<void> _writeFence(String checkoutId, String leaseId, int token) async {
    await _repositoryRoot.createDirectory('.conclave/checkout-fences');
    await _repositoryRoot.write(
      _fenceRelativePath(checkoutId),
      jsonEncode({
        'checkoutId': checkoutId,
        'leaseId': leaseId,
        'fencingToken': token
      }),
    );
  }

  Future<void> resetAndRecover(String checkoutId, {String? revision}) async {
    await withLock(checkoutId, (checkout) async {
      final repo = _repoFor(checkout);
      await repo.resetHard(revision ?? checkout.revision);
    });
  }

  Future<String> checkpointCommit(String checkoutId, String message) async {
    return withLock(checkoutId, (checkout) async {
      return _repoFor(checkout).checkpointCommit(message);
    });
  }

  /// Finalizes one stateful lease. Success commits only when the Checkout is
  /// dirty; failure/cancellation captures bounded diagnostics and restores the
  /// supplied base revision, including controlled untracked files.
  Future<WorkstreamCheckoutLifecycleResult> finalizeStatefulLease({
    required String checkoutId,
    required String baseRevision,
    required String outcome,
    String message = 'workstream checkpoint',
  }) async {
    if (outcome != 'success' &&
        outcome != 'failure' &&
        outcome != 'cancelled') {
      throw const RuntimeViolation('invalid Checkout lifecycle outcome');
    }
    return _withFileLock(checkoutId, () async {
      final checkout = await resolve(checkoutId);
      final before = await _statusForCheckout(checkout);
      final boundedDiff = _boundedText(before.diff);
      if (outcome == 'success') {
        if (!before.dirty) {
          return WorkstreamCheckoutLifecycleResult(
            outcome: outcome,
            revision: before.currentRevision,
            changed: false,
            diff: boundedDiff,
          );
        }
        final revision = await _repoFor(checkout).checkpointCommit(message);
        await _write(WorkstreamCheckout(
          id: checkout.id,
          workstreamId: checkout.workstreamId,
          relativePath: checkout.relativePath,
          branch: checkout.branch,
          revision: revision,
          archived: false,
        ));
        return WorkstreamCheckoutLifecycleResult(
          outcome: outcome,
          revision: revision,
          changed: true,
          diff: boundedDiff,
        );
      }
      try {
        await _repoFor(checkout).resetHard(baseRevision);
        return WorkstreamCheckoutLifecycleResult(
          outcome: outcome,
          revision: await _repoFor(checkout).currentRevision(),
          changed: before.dirty,
          diff: boundedDiff,
          recoveryStatus: 'rolled_back',
        );
      } catch (error) {
        await _writeRecovery(checkoutId, error.toString());
        return WorkstreamCheckoutLifecycleResult(
          outcome: outcome,
          revision: before.currentRevision,
          changed: before.dirty,
          diff: boundedDiff,
          recoveryStatus: 'quarantined',
        );
      }
    });
  }

  String _boundedText(String value, [int maxBytes = 64 * 1024]) {
    if (value.length <= maxBytes) return value;
    return '${value.substring(0, maxBytes)}\n[truncated]';
  }

  Future<void> _writeRecovery(String checkoutId, String error) async {
    await _repositoryRoot.createDirectory('.conclave/checkout-recovery');
    await _repositoryRoot.write(
      '.conclave/checkout-recovery/${_hash(checkoutId)}.json',
      jsonEncode({
        'checkoutId': checkoutId,
        'status': 'quarantined',
        'error': _boundedText(error),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  Future<void> archive(String checkoutId) async {
    await withLock(checkoutId, (checkout) async {
      await _repository.removeWorktree(checkout.relativePath, force: true);
      await _write(WorkstreamCheckout(
        id: checkout.id,
        workstreamId: checkout.workstreamId,
        relativePath: checkout.relativePath,
        branch: checkout.branch,
        revision: checkout.revision,
        archived: true,
      ));
    });
  }

  Future<void> remove(String checkoutId) async {
    await withLock(checkoutId, (checkout) async {
      await _repository.removeWorktree(checkout.relativePath, force: true);
      await _repositoryRoot.delete(_metadataRelativePath(checkout.id));
    });
  }

  GitRepository _repoFor(WorkstreamCheckout checkout) => GitRepository(
        SafeWorkspace(Directory(
            '${_repositoryRoot.root.path}${Platform.pathSeparator}${checkout.relativePath}')),
      );

  Future<void> _write(WorkstreamCheckout checkout) async {
    await _repositoryRoot.write(
      _metadataRelativePath(checkout.id),
      jsonEncode({
        'id': checkout.id,
        'workstreamId': checkout.workstreamId,
        'relativePath': checkout.relativePath,
        'branch': checkout.branch,
        'revision': checkout.revision,
        'archived': checkout.archived,
      }),
    );
  }

  Future<T> withLock<T>(
    String checkoutId,
    Future<T> Function(WorkstreamCheckout checkout) action,
  ) async {
    return _withFileLock(checkoutId, () async {
      final checkout = await resolve(checkoutId);
      return action(checkout);
    });
  }

  Future<T> _withFileLock<T>(
    String checkoutId,
    Future<T> Function() action,
  ) async {
    _validateOpaqueId(checkoutId, 'checkoutId');
    // Advisory file locks do not serialize two handles from the same Dart
    // process consistently on every supported OS. Keep a local queue too;
    // the file lock remains the cross-process fence.
    final previous = _localLocks[checkoutId] ?? Future<void>.value();
    final gate = Completer<void>();
    final queued = previous.then((_) => gate.future);
    _localLocks[checkoutId] = queued;
    await previous;
    RandomAccessFile? handle;
    try {
      await _repositoryRoot.createDirectory('.conclave/checkout-locks');
      final lockFile = File(
          '${_repositoryRoot.root.path}${Platform.pathSeparator}${_lockRelativePath(checkoutId)}');
      handle = await lockFile.open(mode: FileMode.writeOnlyAppend);
      await handle.lock(FileLock.exclusive);
      return await action();
    } finally {
      if (handle != null) {
        try {
          await handle.unlock();
        } finally {
          await handle.close();
        }
      }
      gate.complete();
      if (identical(_localLocks[checkoutId], queued)) {
        _localLocks.remove(checkoutId);
      }
    }
  }
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
