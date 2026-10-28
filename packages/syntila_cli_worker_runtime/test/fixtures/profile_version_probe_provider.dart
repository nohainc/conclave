import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 2 &&
      arguments[0] == 'info' &&
      arguments[1] == '--version') {
    stdout.writeln('wrong-version 99.0.0');
    stderr.writeln('fixture-tool version v1.2.3');
    return;
  }
  if (arguments.length == 1 && arguments.first == 'slow') {
    await Future<void>.delayed(const Duration(seconds: 2));
    stdout.writeln('fixture-tool 1.2.3');
    return;
  }
  stderr.writeln('unexpected arguments: ${arguments.join(' ')}');
  exitCode = 2;
}
