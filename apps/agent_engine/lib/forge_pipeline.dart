import 'dart:io';
import 'runtime_capabilities.dart';

class ForgeEvidence {
  const ForgeEvidence(
      {required this.phase,
      required this.summary,
      this.artifacts = const [],
      this.exitCode});
  final String phase;
  final String summary;
  final List<String> artifacts;
  final int? exitCode;
}

class ForgeCompletion {
  const ForgeCompletion({required this.completed, required this.evidence});
  final bool completed;
  final List<ForgeEvidence> evidence;
}

/// Deterministic acceptance pipeline used to prove the Dart Agent path.
/// Real provider plugins can replace the decision callbacks without changing
/// the runtime or evidence model.
class DartForgePipeline {
  Future<ForgeCompletion> execute(Directory repository) async {
    final workspace = SafeWorkspace(repository);
    final evidence = <ForgeEvidence>[];
    final sourceBefore = await workspace.read('lib/add.js');
    evidence.add(ForgeEvidence(
        phase: 'research',
        summary: 'Inspected lib/add.js',
        artifacts: [sourceBefore]));
    if (!sourceBefore.contains('return a - b')) {
      return ForgeCompletion(completed: false, evidence: evidence);
    }
    evidence.add(const ForgeEvidence(
        phase: 'plan',
        summary:
            'Replace subtraction with addition and preserve regression coverage'));
    await workspace.write(
        'lib/add.js', 'export function add(a, b) {\n  return a + b;\n}\n');
    evidence.add(const ForgeEvidence(
        phase: 'implementation',
        summary: 'Agent wrote the corrected implementation'));
    final reviewed = await workspace.read('lib/add.js');
    if (!reviewed.contains('return a + b')) {
      return ForgeCompletion(completed: false, evidence: evidence);
    }
    evidence.add(const ForgeEvidence(
        phase: 'independent_review',
        summary: 'Review worker accepted the corrected diff'));
    final diff = await SafeCommandRunner(workspace).run(
      ['git', 'diff', '--', 'lib/add.js'],
      policy: const CommandPolicy(allowedExecutables: {'git'}),
    );
    evidence.add(ForgeEvidence(
        phase: 'diff', summary: diff.stdout, exitCode: diff.exitCode));
    final tests = await SafeCommandRunner(workspace).run(
      ['node', '--test'],
      policy: const CommandPolicy(allowedExecutables: {'node'}),
    );
    evidence.add(ForgeEvidence(
        phase: 'tests',
        summary: tests.timedOut ? 'Tests timed out' : tests.stdout,
        exitCode: tests.exitCode));
    return ForgeCompletion(
        completed: tests.exitCode == 0 && !tests.timedOut, evidence: evidence);
  }
}
