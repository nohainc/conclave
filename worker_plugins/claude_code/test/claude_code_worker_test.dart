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
}
