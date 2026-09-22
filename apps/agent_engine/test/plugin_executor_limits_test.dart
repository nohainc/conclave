import 'dart:io';

import 'package:conclave_agent_engine/plugin_executor.dart';
import 'package:test/test.dart';

Future<Directory> createLoudPlugin() async {
  final directory = await Directory.systemTemp.createTemp('loud-plugin-');
  await File('${directory.path}/loud.dart').writeAsString('''
import 'dart:io';

Future<void> main() async {
  stdout.write(List.filled(1024 * 1024, 'x').join());
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
  return directory;
}

void main() {
  test('bounds an unterminated plugin stdout line before line buffering',
      () async {
    final directory = await createLoudPlugin();
    try {
      await expectLater(
        PluginProcessExecutor().execute(
          PluginProcessSpec(
            pluginId: 'loud',
            executable: Platform.resolvedExecutable,
            arguments: ['run', '${directory.path}/loud.dart'],
          ),
          {},
          maxStdoutBytes: 1024,
        ),
        throwsA(predicate((error) =>
            error.toString().contains('plugin stdout exceeded 1024 bytes'))),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
