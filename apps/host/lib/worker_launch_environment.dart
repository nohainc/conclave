import 'dart:convert';
import 'dart:io';

/// Builds the bounded, provider-neutral environment inherited by a Worker.
///
/// Parent PATH entries are retained only when absolute; stable platform
/// locations are appended so GUI-launched Workspace processes can find local
/// tools without relying on shell startup files.
Map<String, String> safeWorkerEnvironment(
  Map<String, String> requested, {
  Set<String> allowedNames = const {},
  Map<String, String>? parentEnvironment,
  String? operatingSystem,
}) {
  final environment = <String, String>{};
  final parent = parentEnvironment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  const maxEntries = 128;
  const maxValueBytes = 64 * 1024;
  const maxTotalBytes = 256 * 1024;
  var totalBytes = 0;
  void add(String name, String value) {
    if (value.isEmpty) return;
    final valueBytes = utf8.encode(value).length;
    if (valueBytes > maxValueBytes ||
        (!environment.containsKey(name) && environment.length >= maxEntries) ||
        totalBytes + name.length + valueBytes > maxTotalBytes) {
      throw StateError('Worker environment exceeds its configured bounds');
    }
    if (environment.containsKey(name)) {
      totalBytes -= name.length + utf8.encode(environment[name]!).length;
    }
    environment[name] = value;
    totalBytes += name.length + valueBytes;
  }

  for (final name in const [
    'HOME',
    'USERPROFILE',
    'TMPDIR',
    'TMP',
    'TEMP',
    'SystemRoot',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
    'NO_COLOR',
    'TERM',
  ]) {
    final value = _environmentValue(parent, name, os);
    if (value != null) add(name, value);
  }
  final path = _workerLaunchPath(
    parentPath: _environmentValue(parent, 'PATH', os),
    homeDirectory: _environmentValue(parent, 'HOME', os) ??
        _environmentValue(parent, 'USERPROFILE', os),
    systemRoot: _environmentValue(parent, 'SystemRoot', os),
    operatingSystem: os,
  );
  if (path.isNotEmpty) add('PATH', path);
  for (final name in allowedNames) {
    if (name == 'PATH') continue;
    final value = _environmentValue(parent, name, os);
    if (value != null) add(name, value);
  }
  add('DART_SUPPRESS_ANALYTICS', '1');
  for (final entry in requested.entries) {
    if (allowedNames.contains(entry.key)) add(entry.key, entry.value);
  }
  return environment;
}

String? _environmentValue(
  Map<String, String> environment,
  String name,
  String operatingSystem,
) {
  if (operatingSystem != 'windows') return environment[name];
  final lowerName = name.toLowerCase();
  for (final entry in environment.entries) {
    if (entry.key.toLowerCase() == lowerName) return entry.value;
  }
  return null;
}

String _workerLaunchPath({
  required String? parentPath,
  required String? homeDirectory,
  required String? systemRoot,
  required String operatingSystem,
}) {
  final isWindows = operatingSystem == 'windows';
  final separator = isWindows ? ';' : ':';
  final defaults = <String>[];
  if (isWindows) {
    final root = systemRoot;
    if (root != null && root.isNotEmpty) {
      defaults.addAll([
        '$root\\System32',
        root,
        '$root\\System32\\Wbem',
        '$root\\System32\\WindowsPowerShell\\v1.0',
      ]);
    }
  } else if (operatingSystem == 'macos') {
    defaults.addAll(const [
      '/opt/homebrew/bin',
      '/opt/homebrew/sbin',
      '/usr/local/bin',
      '/usr/local/sbin',
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
    ]);
  } else {
    defaults.addAll(const [
      '/usr/local/bin',
      '/usr/local/sbin',
      '/usr/bin',
      '/usr/sbin',
      '/bin',
      '/sbin',
    ]);
  }
  if (!isWindows && homeDirectory != null && homeDirectory.isNotEmpty) {
    defaults.addAll([
      '$homeDirectory/.local/bin',
      '$homeDirectory/bin',
    ]);
  }

  final paths = <String>[];
  final seen = <String>{};
  for (final candidate in [
    ...(parentPath ?? '').split(separator),
    ...defaults,
  ]) {
    final path = candidate.trim();
    if (path.isEmpty || !_isAbsoluteWorkerPath(path, isWindows)) continue;
    final key = isWindows ? path.toLowerCase() : path;
    if (seen.add(key)) paths.add(path);
  }
  return paths.join(separator);
}

bool _isAbsoluteWorkerPath(String path, bool isWindows) => isWindows
    ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
    : path.startsWith('/');
