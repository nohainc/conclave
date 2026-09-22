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

/// Deterministic acceptance pipeline used to prove the Dart Host path.
/// Real provider workers can replace the decision callbacks without changing
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
    await workspace.patch('lib/add.js', 'return a - b;', 'return a + b;');
    const regressionTest = '''import test from "node:test";
import assert from "node:assert/strict";
import { add } from "../lib/add.js";

test("adds two numbers", () => {
  assert.equal(add(2, 3), 5);
});
''';
    await workspace.write('test/add.test.js', regressionTest);
    evidence.add(const ForgeEvidence(
        phase: 'implementation',
        summary:
            'Host patched the implementation and added regression coverage through the safe workspace API',
        artifacts: ['lib/add.js', 'test/add.test.js']));
    final reviewRepository = await _copyWorkspace(repository);
    try {
      final reviewWorkspace = SafeWorkspace(reviewRepository);
      final reviewed = await reviewWorkspace.read('lib/add.js');
      final regressionTest = await reviewWorkspace.read('test/add.test.js');
      if (!reviewed.contains('return a + b') ||
          !regressionTest.contains('assert.equal(add(2, 3), 5)')) {
        return ForgeCompletion(
          completed: false,
          evidence: evidence,
          completionReport:
              'Implementation or regression coverage did not satisfy review',
        );
      }
      evidence.add(const ForgeEvidence(
          phase: 'independent_review',
          summary:
              'Independent review inspected a separate workspace clone of the changed repository',
          artifacts: ['lib/add.js', 'test/add.test.js'],
          findings: []));
    } finally {
      await reviewRepository.delete(recursive: true);
    }
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
    evidence.add(ForgeEvidence(
      phase: 'verification',
      summary: completed
          ? 'Verifier accepted the machine test evidence'
          : 'Verifier rejected the machine test evidence',
      command: const ['node', '--test'],
      exitCode: tests.exitCode,
      verification: completed ? 'passed' : 'failed',
    ));
    return ForgeCompletion(
      completed: completed,
      evidence: evidence,
      completionReport: completed
          ? 'All required fixture checks passed at revision ${revision.isEmpty ? 'unknown' : revision}'
          : 'Required fixture checks did not pass',
    );
  }

  Future<Directory> _copyWorkspace(Directory source) async {
    final destination =
        await Directory.systemTemp.createTemp('conclave-forge-review-');
    await _copyDirectoryContents(source, destination);
    return destination;
  }

  Future<void> _copyDirectoryContents(
      Directory source, Directory destination) async {
    await for (final entity in source.list(followLinks: false)) {
      final name = entity.uri.pathSegments.lastWhere(
        (segment) => segment.isNotEmpty,
        orElse: () => '',
      );
      if (name.isEmpty) continue;
      final targetPath = '${destination.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        final target = Directory(targetPath);
        await target.create(recursive: true);
        await _copyDirectoryContents(entity, target);
      } else if (entity is File) {
        await File(targetPath).writeAsBytes(
          await entity.readAsBytes(),
          flush: true,
        );
      }
    }
  }
}
