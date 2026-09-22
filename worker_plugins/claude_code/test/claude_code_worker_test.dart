import 'dart:io';
import 'package:conclave_claude_code_plugin/claude_code_worker.dart';
import 'package:test/test.dart';

void main() {
  test('uses the same worker interface with Claude Code arguments', () async {
    final worker = ClaudeCodeWorker(invoke: (executable, args) async {
      expect(executable, 'claude');
      expect(args, ['-p', 'review diff', '--output-format', 'json']);
      return ProcessResult(1, 0, '{"approved":true}', '');
    });
    expect(await worker.execute('review diff'), '{"approved":true}');
  });

  test('reports version and authentication readiness', () async {
    final worker = ClaudeCodeWorker(invoke: (executable, args) async {
      expect(executable, 'claude');
      if (args.length == 1 && args.first == '--version') {
        return ProcessResult(1, 0, 'Claude Code 2.1.0', '');
      }
      expect(args, ['auth', 'status']);
      return ProcessResult(1, 0, 'authenticated', '');
    });
    final status = await worker.availability();
    expect(status.installed, isTrue);
    expect(status.version, '2.1.0');
    expect(status.authenticated, isTrue);
  });

  test('parses structured Claude Code output and rejects malformed output', () {
    final worker = ClaudeCodeWorker();
    final result = worker.parseStructuredOutput(
        '{"type":"result","result":{"summary":"reviewed","approved":true}}');
    expect(result.summary, 'reviewed');
    expect(result.output['approved'], isTrue);
    expect(
        () => worker.parseStructuredOutput('not json'), throwsFormatException);
  });

  test('bounds CLI output and force-terminates a noisy process', () async {
    final directory = await Directory.systemTemp.createTemp('claude-noisy-');
    final script = File('${directory.path}/noisy.dart')..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  stdout.write(List.filled(1024 * 1024, 'x').join());
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
    final worker = ClaudeCodeWorker(
      start: (executable, arguments, {workingDirectory}) => Process.start(
        Platform.resolvedExecutable,
        ['run', script.path],
        workingDirectory: workingDirectory,
      ),
    );
    try {
      await expectLater(
        worker.executeTask('noisy', maxOutputBytes: 1024),
        throwsA(predicate((error) => error
            .toString()
            .contains('Claude Code output exceeded 1024 bytes'))),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
