import 'dart:io';

Future<File> compileDartExecutable(File source, Directory outputDirectory,
    {required String name}) async {
  final output = File(
      '${outputDirectory.path}${Platform.pathSeparator}$name${Platform.isWindows ? '.exe' : ''}');
  await outputDirectory.create(recursive: true);
  final result =
      await Process.run(Platform.environment['DART_EXECUTABLE'] ?? 'dart', [
    'compile',
    'exe',
    source.path,
    '-o',
    output.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError(
        'Could not compile test adapter: ${result.stdout}\n${result.stderr}');
  }
  return output;
}
