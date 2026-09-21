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
}
