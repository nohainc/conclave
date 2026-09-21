import 'dart:io';
import 'package:conclave_agent_engine/forge_pipeline.dart';
import 'package:test/test.dart';

void main() {
  test('completes Forge against the real fixture repository', () async {
    final repository = Directory(
      '${Directory.current.parent.parent.path}/fixtures/conclave-e2e-fixture',
    );
    final source = File('${repository.path}/lib/add.js');
    await source
        .writeAsString('export function add(a, b) {\n  return a - b;\n}\n');
    try {
      final result = await DartForgePipeline().execute(repository);
      expect(result.completed, isTrue);
      expect(result.evidence.map((item) => item.phase), [
        'research',
        'plan',
        'implementation',
        'independent_review',
        'diff',
        'tests',
      ]);
      expect(result.evidence[4].summary, contains('return a + b'));
      expect(result.evidence.last.exitCode, 0);
    } finally {
      await source
          .writeAsString('export function add(a, b) {\n  return a - b;\n}\n');
    }
  });
}
