import 'dart:io';

import 'adapter_prerequisite.dart';
import 'first_party_worker_adapter_descriptor.dart';

/// The executable selected for a first-party CLI after a bounded version probe.
class FirstPartyWorkerCliExecutable {
  const FirstPartyWorkerCliExecutable({
    required this.path,
    required this.versionProbe,
  });

  final String path;
  final AdapterPrerequisiteResult versionProbe;
}

class FirstPartyCliResolutionException implements Exception {
  const FirstPartyCliResolutionException.cliNotFound()
      : reasonCode = 'cli_not_found',
        executablePath = null,
        detectedVersion = null;

  const FirstPartyCliResolutionException.unsupportedVersion(
    this.executablePath,
    this.detectedVersion,
  ) : reasonCode = 'unsupported_cli_version';

  final String reasonCode;
  final String? executablePath;
  final String? detectedVersion;

  @override
  String toString() => 'First-party CLI probe failed: $reasonCode';
}

/// Resolves cached CLI paths first, then the launch environment's PATH, then
/// known installation directories. Candidate paths are returned only after
/// the descriptor's version requirements pass.
class FirstPartyWorkerCliExecutableLocator {
  const FirstPartyWorkerCliExecutableLocator({
    this.probeExecutable = probeAdapterExecutable,
    this.environment,
    this.knownDirectories,
  });

  final Future<AdapterPrerequisiteResult> Function(
    AdapterExecutablePrerequisite prerequisite, {
    String? searchPath,
  }) probeExecutable;
  final Map<String, String>? environment;
  final List<String>? knownDirectories;

  Future<FirstPartyWorkerCliExecutable?> locate(
    FirstPartyWorkerAdapterDescriptor descriptor, {
    String? cachedPath,
  }) async {
    final candidates = <String>[];
    if (cachedPath != null && _isAbsolute(cachedPath)) {
      candidates.add(cachedPath);
    }
    final env = environment ?? Platform.environment;
    final separator = Platform.isWindows ? ';' : ':';
    final path = env['PATH'] ?? '';
    for (final directory in path.split(separator)) {
      if (directory.isNotEmpty) {
        for (final executable in descriptor.executableCandidates) {
          candidates.add(_join(directory, executable));
        }
      }
    }
    for (final directory
        in knownDirectories ?? workspaceKnownCliDirectories(environment: env)) {
      for (final executable in descriptor.executableCandidates) {
        candidates.add(_join(directory, executable));
      }
    }

    final seen = <String>{};
    FirstPartyWorkerCliExecutable? unsupported;
    for (final candidate in candidates) {
      final absolute = _absolute(candidate);
      if (absolute == null || !seen.add(absolute)) continue;
      final file = File(absolute);
      if (!await file.exists()) continue;
      final versionRange = descriptor.supportedCliVersionRange;
      final probe = await probeExecutable(
        AdapterExecutablePrerequisite(
          executable: file.path.split(Platform.pathSeparator).last,
          minimumVersion: versionRange.minimum,
          maximumVersion: versionRange.maximum,
          versionArgs: descriptor.probeStrategy.versionArguments,
        ),
        searchPath: file.parent.path,
      );
      if (probe.satisfied) {
        return FirstPartyWorkerCliExecutable(
            path: absolute, versionProbe: probe);
      }
      if (probe.detectedVersion != null && unsupported == null) {
        unsupported = FirstPartyWorkerCliExecutable(
          path: absolute,
          versionProbe: probe,
        );
      }
    }
    return unsupported;
  }

  static String _join(String directory, String name) =>
      '$directory${Platform.pathSeparator}$name';

  static String? _absolute(String value) {
    if (!_isAbsolute(value)) return null;
    try {
      return File(value).absolute.path;
    } on Object {
      return null;
    }
  }

  static bool _isAbsolute(String value) => Platform.isWindows
      ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith(r'\\')
      : value.startsWith('/');
}
