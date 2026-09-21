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
}
