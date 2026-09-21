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
}
