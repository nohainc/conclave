import 'package:conclave_host/forge_pipeline.dart';
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
        'verification',
      ]);
      expect(result.evidence[4].summary, contains('return a + b'));
      expect(result.evidence[2].artifacts,
          containsAll(['lib/add.js', 'test/add.test.js']));
      expect(
          result.evidence.first.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
      expect(result.evidence[4].command, ['git', 'diff', '--', 'lib/add.js']);
      expect(result.evidence.last.verification, 'passed');
      expect(result.completionReport,
          contains('All required fixture checks passed'));
      expect(result.evidence.last.exitCode, 0);
    } finally {
      await repository.parent.delete(recursive: true);
    }
  });
}
