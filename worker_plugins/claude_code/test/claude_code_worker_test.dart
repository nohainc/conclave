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

  test('forwards bounded task context to the Claude prompt', () {
    final prompt = buildClaudeCodeTaskPrompt('review repository', {
      'evidence': 'return a - b',
      'repositoryPath': '/repo',
    });
    expect(prompt, contains('review repository'));
    expect(prompt, contains('return a - b'));
    expect(
        buildClaudeCodeTaskPrompt('task', {'large': 'x' * 200}, maxBytes: 32),
        contains('[context truncated]'));
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

  test('cancels a running Claude Code CLI process', () async {
    final directory = await Directory.systemTemp.createTemp('claude-cancel-');
    final script = File('${directory.path}/waiting.dart')..writeAsStringSync('''
import 'dart:async';
Future<void> main() async => Future<void>.delayed(const Duration(seconds: 5));
''');
    final token = ClaudeCodeCancellationToken();
    final worker = ClaudeCodeWorker(
      start: (executable, arguments, {workingDirectory}) => Process.start(
        Platform.resolvedExecutable,
        ['run', script.path],
        workingDirectory: workingDirectory,
      ),
    );
    final execution = worker.executeTask('wait', cancellation: token);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    token.cancel();
    await expectLater(
      execution,
      throwsA(predicate((error) => error.toString().contains('cancelled'))),
    );
    await directory.delete(recursive: true);
  });
}
