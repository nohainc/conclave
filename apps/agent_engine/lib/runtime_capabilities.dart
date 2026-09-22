import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'process_tree.dart';
import 'trust_policy.dart';

class RuntimeViolation implements Exception {
  const RuntimeViolation(this.message);
  final String message;
  @override
  String toString() => 'RuntimeViolation: $message';
}

class SafeWorkspace {
  SafeWorkspace(Directory root) : root = root.absolute;
  final Directory root;

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
    if (!lexical.startsWith(lexicalRoot) && lexical != root.path) {
      throw const RuntimeViolation('path escapes workspace root');
    }
    final candidate = File('${root.path}/$relative').absolute;
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
    if (!normalized.startsWith(normalizedRoot) && resolved != rootReal) {
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
      if (relative
          .split(Platform.pathSeparator)
          .any(ignoredDirectories.contains)) {
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
    final prefix = root.path.endsWith(Platform.pathSeparator)
        ? root.path
        : '${root.path}${Platform.pathSeparator}';
    if (!absolutePath.startsWith(prefix)) {
      throw const RuntimeViolation('path escapes workspace root');
    }
    final relative = absolutePath.substring(prefix.length);
    return relative == '.' ? relative : relative.replaceFirst('./', '');
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
