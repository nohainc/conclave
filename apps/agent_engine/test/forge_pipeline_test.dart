import 'package:conclave_agent_engine/forge_pipeline.dart';
import 'package:test/test.dart';
import 'fixture_copy.dart';

void main() {
  test('completes Forge against the real fixture repository', () async {
    final repository = await copyForgeFixture();
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
      await repository.parent.delete(recursive: true);
    }
  });
}
