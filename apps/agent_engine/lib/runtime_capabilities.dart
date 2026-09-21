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
    if (forWrite && existing && await Link(candidate.path).exists()) {
      throw const RuntimeViolation('writes through symlinks are not allowed');
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

  Future<void> delete(String relative) async {
    final path = await _contained(relative, forWrite: true);
    await File(path).delete();
  }

  Future<String> digest(String relative) async {
    final path = await _contained(relative);
    return sha256.convert(await File(path).readAsBytes()).toString();
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

class RuntimeArtifact {
  const RuntimeArtifact(
      {required this.path, required this.sizeBytes, required this.sha256});
  final String path;
  final int sizeBytes;
  final String sha256;
}

Future<RuntimeArtifact> stageArtifact(File file) async {
  final size = await file.length();
  final digest = sha256.convert(await file.readAsBytes());
  return RuntimeArtifact(
      path: file.path, sizeBytes: size, sha256: digest.toString());
}
