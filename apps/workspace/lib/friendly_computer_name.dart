import 'dart:async';
import 'dart:io';

import 'platform_runtime.dart';

typedef CommandRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

typedef FileReader = String? Function(String path);

/// Resolves a human-friendly computer name for proposing the initial Workspace display name.
///
/// Hierarchy:
/// 1. Friendly OS computer name:
///    - macOS: `scutil --get ComputerName` (e.g. "Vitalii's MacBook Pro")
///    - Windows: `COMPUTERNAME` environment variable
///    - Linux: `hostnamectl --pretty` or `PRETTY_HOSTNAME` in `/etc/machine-info`
/// 2. Cleaned hostname fallback (stripping `.local`, `.lan`, `.localdomain`, etc.)
/// 3. Platform generic fallback: "My Mac", "My PC", "My Workspace"
Future<String> resolveFriendlyComputerName({
  PlatformRuntime? platform,
  Map<String, String>? environment,
  CommandRunner? runCommand,
  FileReader? readFile,
  String? localHostname,
}) async {
  final env = environment ?? Platform.environment;
  final os =
      (platform?.operatingSystem ?? Platform.operatingSystem).toLowerCase();
  final runner = runCommand ?? Process.run;
  final reader = readFile ??
      (path) {
        try {
          final file = File(path);
          if (file.existsSync()) return file.readAsStringSync();
        } on Object {
          // Fall back gracefully
        }
        return null;
      };

  // 1. OS-specific friendly computer name
  if (os == 'macos') {
    try {
      final result = await runner('scutil', ['--get', 'ComputerName']);
      if (result.exitCode == 0) {
        final name = (result.stdout?.toString() ?? '').trim();
        if (_isValidFriendlyName(name)) {
          return name;
        }
      }
    } on Object {
      // Fallback
    }
  } else if (os == 'windows' || platform?.isWindows == true) {
    final computerName = env['COMPUTERNAME']?.trim();
    if (computerName != null && _isValidFriendlyName(computerName)) {
      return computerName;
    }
  } else if (os == 'linux') {
    try {
      final result = await runner('hostnamectl', ['--pretty']);
      if (result.exitCode == 0) {
        final name = (result.stdout?.toString() ?? '').trim();
        if (_isValidFriendlyName(name)) {
          return name;
        }
      }
    } on Object {
      // Fallback
    }

    final machineInfo = reader('/etc/machine-info');
    if (machineInfo != null && machineInfo.isNotEmpty) {
      final match = RegExp(
        r'^PRETTY_HOSTNAME=(?:"([^"]+)"|([^\r\n]+))',
        multiLine: true,
      ).firstMatch(machineInfo);
      final pretty = (match?.group(1) ?? match?.group(2))?.trim();
      if (pretty != null && _isValidFriendlyName(pretty)) {
        return pretty;
      }
    }
  }

  // 2. Cleaned hostname fallback
  final rawHost = localHostname ?? Platform.localHostname;
  final cleanedHost = _cleanHostname(rawHost);
  if (_isValidFriendlyName(cleanedHost)) {
    return cleanedHost;
  }

  // 3. Platform generic fallback
  return _genericPlatformFallback(os);
}

/// Synchronous resolution helper when async Process execution is unavailable.
String resolveFriendlyComputerNameSync({
  PlatformRuntime? platform,
  Map<String, String>? environment,
  FileReader? readFile,
  String? localHostname,
}) {
  final env = environment ?? Platform.environment;
  final os =
      (platform?.operatingSystem ?? Platform.operatingSystem).toLowerCase();
  final reader = readFile ??
      (path) {
        try {
          final file = File(path);
          if (file.existsSync()) return file.readAsStringSync();
        } on Object {
          // Fall back gracefully
        }
        return null;
      };

  if (os == 'windows' || platform?.isWindows == true) {
    final computerName = env['COMPUTERNAME']?.trim();
    if (computerName != null && _isValidFriendlyName(computerName)) {
      return computerName;
    }
  } else if (os == 'linux') {
    final machineInfo = reader('/etc/machine-info');
    if (machineInfo != null && machineInfo.isNotEmpty) {
      final match = RegExp(
        r'^PRETTY_HOSTNAME=(?:"([^"]+)"|([^\r\n]+))',
        multiLine: true,
      ).firstMatch(machineInfo);
      final pretty = (match?.group(1) ?? match?.group(2))?.trim();
      if (pretty != null && _isValidFriendlyName(pretty)) {
        return pretty;
      }
    }
  }

  final rawHost = localHostname ?? Platform.localHostname;
  final cleanedHost = _cleanHostname(rawHost);
  if (_isValidFriendlyName(cleanedHost)) {
    return cleanedHost;
  }

  return _genericPlatformFallback(os);
}

bool _isValidFriendlyName(String? name) {
  if (name == null) return false;
  final trimmed = name.trim();
  if (trimmed.isEmpty) return false;
  final lower = trimmed.toLowerCase();
  if (lower == 'localhost' ||
      lower == 'localhost.localdomain' ||
      lower == '127.0.0.1' ||
      lower == '::1' ||
      lower == '0.0.0.0' ||
      lower == 'unknown' ||
      lower == '(none)') {
    return false;
  }
  return true;
}

String _cleanHostname(String rawHostname) {
  var name = rawHostname.trim();
  name = name.replaceAll(
    RegExp(r'\.(local|lan|localdomain|home|internal)$', caseSensitive: false),
    '',
  );
  return name.trim();
}

String _genericPlatformFallback(String os) {
  switch (os.toLowerCase()) {
    case 'macos':
      return 'My Mac';
    case 'windows':
      return 'My PC';
    default:
      return 'My Workspace';
  }
}
