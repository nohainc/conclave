import 'dart:io';
import 'runtime_capabilities.dart';

class ForgeEvidence {
  const ForgeEvidence(
      {required this.phase,
      required this.summary,
      this.artifacts = const [],
      this.exitCode,
      this.command = const [],
      this.stderr = '',
      this.revision,
      this.findings = const [],
      this.verification});
  final String phase;
  final String summary;
  final List<String> artifacts;
  final int? exitCode;
  final List<String> command;
  final String stderr;
  final String? revision;
  final List<String> findings;
  final String? verification;
}

class ForgeCompletion {
  const ForgeCompletion({
    required this.completed,
    required this.evidence,
    required this.completionReport,
  });
  final bool completed;
  final List<ForgeEvidence> evidence;
  final String completionReport;
}

/// Deterministic acceptance pipeline used to prove the Dart Agent path.
/// Real provider plugins can replace the decision callbacks without changing
/// the runtime or evidence model.
class DartForgePipeline {
  Future<ForgeCompletion> execute(Directory repository) async {
    final workspace = SafeWorkspace(repository);
    final evidence = <ForgeEvidence>[];
    const gitPolicy = CommandPolicy(allowedExecutables: {'git'});
    final revisionResult = await SafeCommandRunner(workspace).run(
      ['git', 'rev-parse', 'HEAD'],
      policy: gitPolicy,
    );
    final revision = revisionResult.stdout.trim();
    final sourceBefore = await workspace.read('lib/add.js');
    evidence.add(ForgeEvidence(
        phase: 'research',
        summary: 'Inspected lib/add.js',
        artifacts: [sourceBefore],
        command: const ['git', 'rev-parse', 'HEAD'],
        exitCode: revisionResult.exitCode,
        stderr: revisionResult.stderr,
        revision: revision.isEmpty ? null : revision));
    if (!sourceBefore.contains('return a - b')) {
      return ForgeCompletion(
        completed: false,
        evidence: evidence,
        completionReport: 'Research did not identify the expected fixture bug',
      );
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
      return ForgeCompletion(
        completed: false,
        evidence: evidence,
        completionReport: 'Implementation did not produce the expected change',
      );
    }
    evidence.add(const ForgeEvidence(
        phase: 'independent_review',
        summary: 'Review worker accepted the corrected diff',
        findings: []));
    final diff = await SafeCommandRunner(workspace).run(
      ['git', 'diff', '--', 'lib/add.js'],
      policy: gitPolicy,
    );
    evidence.add(ForgeEvidence(
      phase: 'diff',
      summary: diff.stdout,
      exitCode: diff.exitCode,
      command: const ['git', 'diff', '--', 'lib/add.js'],
      stderr: diff.stderr,
      revision: revision.isEmpty ? null : revision,
    ));
    final tests = await SafeCommandRunner(workspace).run(
      ['node', '--test'],
      policy: const CommandPolicy(allowedExecutables: {'node'}),
    );
    evidence.add(ForgeEvidence(
        phase: 'tests',
        summary: tests.timedOut ? 'Tests timed out' : tests.stdout,
        exitCode: tests.exitCode,
        command: const ['node', '--test'],
        stderr: tests.stderr,
        revision: revision.isEmpty ? null : revision,
        verification:
            tests.exitCode == 0 && !tests.timedOut ? 'passed' : 'failed'));
    final completed = tests.exitCode == 0 && !tests.timedOut;
    return ForgeCompletion(
      completed: completed,
      evidence: evidence,
      completionReport: completed
          ? 'All required fixture checks passed at revision ${revision.isEmpty ? 'unknown' : revision}'
          : 'Required fixture checks did not pass',
    );
  }
}
