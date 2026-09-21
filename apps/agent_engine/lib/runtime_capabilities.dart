import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

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
      this.maxOutputBytes = 256 * 1024,
      this.timeout = const Duration(minutes: 2)});
  final Set<String> allowedExecutables;
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
    final cwd = Directory(await workspace._contained(workingDirectory));
    final process = await Process.start(command.first, command.skip(1).toList(),
        workingDirectory: cwd.path,
        environment: const {'PATH': '/usr/bin:/bin'});
    final stdoutFuture = _bounded(process.stdout, policy.maxOutputBytes);
    final stderrFuture = _bounded(process.stderr, policy.maxOutputBytes);
    var timedOut = false;
    final exit = process.exitCode.timeout(policy.timeout, onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    return CommandResult(
        exitCode: await exit,
        stdout: await stdoutFuture,
        stderr: await stderrFuture,
        timedOut: timedOut);
  }

  Future<String> _bounded(Stream<List<int>> stream, int maxBytes) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      if (bytes.length < maxBytes) {
        bytes.addAll(chunk.take(maxBytes - bytes.length));
      }
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
