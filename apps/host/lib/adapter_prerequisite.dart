import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'process_tree.dart';

final _semanticVersion = RegExp(r'(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+)?');
final _semanticVersionConstraint =
    RegExp(r'^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$');
final _commandName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$');

/// A declarative prerequisite copied from a verified adapter manifest.
class AdapterExecutablePrerequisite {
  const AdapterExecutablePrerequisite({
    required this.executable,
    this.minimumVersion,
    this.maximumVersion,
    this.versionArgs = const ['--version'],
  });

  final String executable;
  final String? minimumVersion;
  final String? maximumVersion;
  final List<String> versionArgs;

  factory AdapterExecutablePrerequisite.fromJson(Object? input) {
    if (input is! Map) {
      throw const FormatException('prerequisite must be an object');
    }
    final value = Map<String, Object?>.from(input);
    const allowed = {
      'kind',
      'executable',
      'minimumVersion',
      'maximumVersion',
      'versionArgs',
      'installHelpUrl',
      'installHelpMessage',
    };
    if (value.keys.any((key) => !allowed.contains(key)) ||
        value['kind'] != 'executable') {
      throw const FormatException('unsupported executable prerequisite fields');
    }
    final executable = value['executable'];
    if (executable is! String || !_commandName.hasMatch(executable)) {
      throw const FormatException(
          'prerequisite executable must be a command name, not a path');
    }
    String? version(String key) {
      final raw = value[key];
      if (raw == null) return null;
      if (raw is! String || !_semanticVersionConstraint.hasMatch(raw)) {
        throw FormatException('$key must be a semantic version');
      }
      return raw;
    }

    final args = value['versionArgs'] ?? const ['--version'];
    if (args is! List ||
        args.length > 16 ||
        args.any((arg) => arg is! String || arg.length > 256)) {
      throw const FormatException('versionArgs must be a bounded string list');
    }
    return AdapterExecutablePrerequisite(
      executable: executable,
      minimumVersion: version('minimumVersion'),
      maximumVersion: version('maximumVersion'),
      versionArgs: List.unmodifiable(args.cast<String>()),
    );
  }
}

class AdapterPrerequisiteResult {
  const AdapterPrerequisiteResult({
    required this.satisfied,
    required this.message,
    this.detectedVersion,
  });

  final bool satisfied;
  final String message;
  final String? detectedVersion;
}

/// Detects a manifest-declared command without a shell and with bounded output.
/// The manifest can provide a command name only; PATH remains Workspace-owned.
Future<AdapterPrerequisiteResult> probeAdapterExecutable(
  AdapterExecutablePrerequisite prerequisite, {
  Duration timeout = const Duration(seconds: 5),
  int maxOutputBytes = 8192,
  String? searchPath,
}) async {
  if (!_commandName.hasMatch(prerequisite.executable)) {
    throw ArgumentError('prerequisite executable must be a command name');
  }
  if (timeout <= Duration.zero || maxOutputBytes < 128) {
    throw ArgumentError('prerequisite probe bounds must be positive');
  }
  final inheritedPath = searchPath ?? Platform.environment['PATH'] ?? '';
  Process process;
  try {
    process = await startIsolatedProcess(
      prerequisite.executable,
      prerequisite.versionArgs,
      environment: {
        'PATH': inheritedPath,
        for (final name in const ['SystemRoot', 'WINDIR', 'TEMP', 'TMP'])
          if (Platform.environment[name] case final value?) name: value,
      },
      includeParentEnvironment: false,
    );
  } on ProcessException {
    return AdapterPrerequisiteResult(
      satisfied: false,
      message:
          'Required executable is not available: ${prerequisite.executable}',
    );
  }

  var outputBytes = 0;
  final output = StringBuffer();
  var exceeded = false;
  var killRequested = false;
  void collect(List<int> chunk) {
    outputBytes += chunk.length;
    if (outputBytes > maxOutputBytes) {
      exceeded = true;
      if (!killRequested) {
        killRequested = true;
        unawaited(terminateProcessTree(process, force: true));
      }
      return;
    }
    output.write(utf8.decode(chunk, allowMalformed: true));
  }

  final stdoutDone = process.stdout.listen(collect).asFuture<void>();
  final stderrDone = process.stderr.listen(collect).asFuture<void>();
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
    await Future.wait([stdoutDone, stderrDone]).timeout(timeout);
  } on TimeoutException {
    await terminateProcessTree(process, force: true);
    return const AdapterPrerequisiteResult(
      satisfied: false,
      message: 'Prerequisite version check timed out.',
    );
  }
  if (exceeded) {
    await terminateProcessTree(process, force: true);
    return const AdapterPrerequisiteResult(
      satisfied: false,
      message: 'Prerequisite version output exceeded its limit.',
    );
  }
  if (exitCode != 0) {
    return AdapterPrerequisiteResult(
      satisfied: false,
      message: 'Prerequisite version check exited with code $exitCode.',
    );
  }
  final match = _semanticVersion.firstMatch(output.toString());
  if (match == null) {
    return const AdapterPrerequisiteResult(
      satisfied: false,
      message: 'Prerequisite did not report a supported version.',
    );
  }
  final detected = '${match[1]}.${match[2]}.${match[3]}';
  if (prerequisite.minimumVersion case final minimum?
      when _compareVersions(detected, minimum) < 0) {
    return AdapterPrerequisiteResult(
      satisfied: false,
      detectedVersion: detected,
      message: 'Prerequisite $detected is older than required $minimum.',
    );
  }
  if (prerequisite.maximumVersion case final maximum?
      when _compareVersions(detected, maximum) > 0) {
    return AdapterPrerequisiteResult(
      satisfied: false,
      detectedVersion: detected,
      message: 'Prerequisite $detected is newer than supported $maximum.',
    );
  }
  return AdapterPrerequisiteResult(
    satisfied: true,
    detectedVersion: detected,
    message: 'Prerequisite $detected is available.',
  );
}

int _compareVersions(String left, String right) {
  final a = _semanticVersion.firstMatch(left)!;
  final b = _semanticVersion.firstMatch(right)!;
  for (var index = 1; index <= 3; index++) {
    final comparison = int.parse(a[index]!).compareTo(int.parse(b[index]!));
    if (comparison != 0) return comparison;
  }
  String? prerelease(String value) {
    final match = RegExp(r'^\d+\.\d+\.\d+(?:-([^+]+))?').firstMatch(value);
    return match?.group(1);
  }

  final leftPrerelease = prerelease(left);
  final rightPrerelease = prerelease(right);
  if (leftPrerelease == null || rightPrerelease == null) {
    if (leftPrerelease != rightPrerelease) {
      return leftPrerelease == null ? 1 : -1;
    }
    return 0;
  }
  final leftParts = leftPrerelease.split('.');
  final rightParts = rightPrerelease.split('.');
  for (var index = 0;
      index < leftParts.length && index < rightParts.length;
      index++) {
    final aPart = leftParts[index];
    final bPart = rightParts[index];
    final aNumber = int.tryParse(aPart);
    final bNumber = int.tryParse(bPart);
    final comparison = aNumber != null && bNumber != null
        ? aNumber.compareTo(bNumber)
        : aNumber != null
            ? -1
            : bNumber != null
                ? 1
                : aPart.compareTo(bPart);
    if (comparison != 0) return comparison;
  }
  return leftParts.length.compareTo(rightParts.length);
}
