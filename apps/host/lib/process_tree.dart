import 'dart:io';

import 'platform_runtime.dart';

Future<Process> startIsolatedProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  return currentPlatformRuntime.startIsolatedProcess(executable, arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment);
}

Future<void> terminateProcessTree(
  Process process, {
  required bool force,
}) async {
  await currentPlatformRuntime.terminateProcessTree(process, force: force);
}
