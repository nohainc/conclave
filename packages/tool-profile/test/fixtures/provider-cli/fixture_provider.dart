import 'dart:io';

const version = '0.3.0';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('fixture-provider $version');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'probe') {
    stdout.writeln('ready');
    return;
  }
  if (arguments.length == 2 && arguments.first == 'echo') {
    if (arguments[1] == 'Reply with exactly the word OK. Do not use tools.') {
      stdout.writeln('OK');
      return;
    }
    stdout.writeln('fixture echo: ${arguments[1]}');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'hang') {
    await Future<void>.delayed(const Duration(seconds: 30));
    return;
  }
  if (arguments.length == 1 && arguments.single == 'flood') {
    for (var index = 0; index < 128; index++) {
      stdout.writeln('x' * 65536);
      await stdout.flush();
    }
    return;
  }
  if (arguments.length == 1 && arguments.single == 'stderr-flood') {
    for (var index = 0; index < 128; index++) {
      stderr.writeln('x' * 65536);
      await stderr.flush();
    }
    return;
  }
  stderr.writeln('unsupported fixture-provider command');
  exitCode = 2;
}
