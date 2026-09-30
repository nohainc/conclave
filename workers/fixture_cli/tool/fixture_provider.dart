import 'dart:io';

const version = '0.3.0';

void main(List<String> arguments) {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('fixture-provider $version');
    return;
  }
  if (arguments.length == 1 && arguments.single == 'probe') {
    stdout.writeln('ready');
    return;
  }
  if (arguments.length == 2 && arguments.first == 'echo') {
    stdout.writeln('fixture echo: ${arguments[1]}');
    return;
  }
  stderr.writeln('unsupported fixture-provider command');
  exitCode = 2;
}
