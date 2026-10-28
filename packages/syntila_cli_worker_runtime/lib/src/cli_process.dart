import 'dart:io';

import 'cli_executable_locator.dart';

/// Executes Windows npm command shims as Node entry points without cmd.exe.
/// Unknown batch programs fail closed: arbitrary CLI arguments must never be
/// interpolated into a shell command. Profiles can declare a direct executable.
Future<Process> startCliProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
}) async {
  if (runInShell) throw ArgumentError('CLI processes must not use a shell');
  var target = executable;
  var argv = arguments;
  if (Platform.isWindows &&
      RegExp(r'\.(cmd|bat)$', caseSensitive: false).hasMatch(executable)) {
    final shim = File(executable);
    if (await shim.length() > 65536)
      throw const FormatException('CLI shim exceeds limit');
    final script = await shim.readAsString();
    final entry = npmShimEntryPoint(script);
    final nodeScript = File('${shim.parent.path}/$entry');
    if (!await nodeScript.exists())
      throw const FormatException('CLI shim entry point is missing');
    final adjacentNode = File('${shim.parent.path}/node.exe');
    final node = await adjacentNode.exists()
        ? adjacentNode.path
        : await const CliExecutableLocator().locate(
            'node',
            environment: environment,
          );
    if (node == null)
      throw const FormatException(
        'Node executable required by CLI shim is missing',
      );
    target = node;
    argv = [nodeScript.path, ...arguments];
  }
  return Process.start(
    target,
    argv,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: false,
  );
}

String npmShimEntryPoint(String script) {
  if (script.length > 65536 ||
      !script.contains('%*') ||
      !RegExp(r'node(?:\.exe)?', caseSensitive: false).hasMatch(script)) {
    throw const FormatException(
      'Unsupported batch CLI; configure a direct executable',
    );
  }
  final matches = RegExp(
    r'"%(?:dp0%|~dp0)[\\/]?(node_modules[\\/][^"\r\n%]*\.(?:js|mjs|cjs))"',
    caseSensitive: false,
  ).allMatches(script).map((m) => m.group(1)!.replaceAll('\\', '/')).toSet();
  if (matches.length != 1)
    throw const FormatException('Unsupported or ambiguous npm CLI shim');
  final entry = matches.single;
  if (entry
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..') ||
      entry.contains('\u0000')) {
    throw const FormatException('Invalid npm CLI shim entry point');
  }
  return entry;
}
