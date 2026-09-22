import 'dart:io';
import 'package:conclave_codex_plugin/codex_worker.dart';
import 'package:test/test.dart';

void main() {
  test('uses the generic Worker Plugin command boundary', () async {
    final worker = CodexWorker(invoke: (executable, args) async {
      expect(executable, 'codex');
      expect(args.first, 'exec');
      return ProcessResult(1, 0, '{"summary":"done"}', '');
    });
    expect(await worker.execute('inspect repository'), '{"summary":"done"}');
  });

  test('reports installation, version, and authentication without secrets',
      () async {
    final worker = CodexWorker(invoke: (executable, args) async {
      expect(executable, 'codex');
      if (args.length == 1 && args.first == '--version') {
        return ProcessResult(1, 0, 'codex-cli 1.2.3', '');
      }
      expect(args, ['login', 'status']);
      return ProcessResult(1, 0, 'logged in as user@example.com', '');
    });
    final status = await worker.availability();
    expect(status.installed, isTrue);
    expect(status.version, '1.2.3');
    expect(status.authenticated, isTrue);
  });

  test('parses newline-delimited structured Codex output', () {
    final result = CodexWorker().parseStructuredOutput('''
{"type":"progress","message":"researching"}
{"type":"result","result":{"summary":"fixed bug","files":2}}
''');
    expect(result.summary, 'fixed bug');
    expect(result.output['files'], 2);
    expect(result.events, hasLength(2));
  });

  test('rejects malformed or empty structured output', () {
    final worker = CodexWorker();
    expect(
        () => worker.parseStructuredOutput('not json'), throwsFormatException);
    expect(() => worker.parseStructuredOutput('  '), throwsFormatException);
  });

  test('bounds CLI output and force-terminates a noisy process', () async {
    final directory = await Directory.systemTemp.createTemp('codex-noisy-');
    final script = File('${directory.path}/noisy.dart')..writeAsStringSync('''
import 'dart:io';
Future<void> main() async {
  stdout.write(List.filled(1024 * 1024, 'x').join());
  await Future<void>.delayed(const Duration(seconds: 5));
}
''');
    final worker = CodexWorker(
      start: (executable, arguments, {workingDirectory}) => Process.start(
        Platform.resolvedExecutable,
        ['run', script.path],
        workingDirectory: workingDirectory,
      ),
    );
    try {
      await expectLater(
        worker.executeTask('noisy', maxOutputBytes: 1024),
        throwsA(predicate((error) =>
            error.toString().contains('Codex output exceeded 1024 bytes'))),
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
