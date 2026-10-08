import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  for (final profile in _profiles) {
    final enabled = Platform.environment[profile.optInVariable] == '1';
    group('live ${profile.workerTypeId} assignment acceptance', () {
      test(
        profile.workerTypeId == 'chatgpt' ? 'Work → ChatGPT' : 'Work → Gemini',
        skip: enabled
            ? false
            : 'Set ${profile.optInVariable}=1 to use provider allowance',
        timeout: const Timeout(Duration(minutes: 5)),
        () => _withRuntime(profile, (run, directory) async {
          final response = await run(
            'direct',
            'Reply with exactly DIRECT_${profile.workerTypeId.toUpperCase()}_OK.',
          );
          expect(response,
              contains('DIRECT_${profile.workerTypeId.toUpperCase()}_OK'));
        }),
      );

      test(
        'Plan & Implement',
        skip: enabled
            ? false
            : 'Set ${profile.optInVariable}=1 to use provider allowance',
        timeout: const Timeout(Duration(minutes: 8)),
        () => _withRuntime(profile, (run, directory) async {
          const marker = 'plan-and-implement.txt';
          final plan = await run(
            'plan',
            'Plan one change in the current directory: create $marker with '
                'exactly PLAN_IMPLEMENTED. Reply with a one-sentence plan only; '
                'do not edit files.',
            policy: WorkerExecutionPolicy.providerDefault,
          );
          expect(plan, isNotEmpty);
          final implementation = await run(
            'implement',
            'Implement this plan: $plan. Create $marker containing exactly '
                'PLAN_IMPLEMENTED. Reply with exactly IMPLEMENTED.',
          );
          expect(implementation, contains('IMPLEMENTED'));
          expect(
            (await File('${directory.path}/$marker').readAsString()).trim(),
            'PLAN_IMPLEMENTED',
          );
        }),
      );

      test(
        'Implement & Verify',
        skip: enabled
            ? false
            : 'Set ${profile.optInVariable}=1 to use provider allowance',
        timeout: const Timeout(Duration(minutes: 8)),
        () => _withRuntime(profile, (run, directory) async {
          const marker = 'implement-and-verify.txt';
          final implementation = await run(
            'implement',
            'Create $marker in the current directory with exactly '
                'IMPLEMENT_VERIFY. Reply with exactly IMPLEMENTED.',
          );
          expect(implementation, contains('IMPLEMENTED'));
          final verification = await run(
            'verify',
            'Read $marker. If its entire content is IMPLEMENT_VERIFY, reply '
                'exactly VERIFY_OK; otherwise reply VERIFY_FAILED.',
            policy: WorkerExecutionPolicy.providerDefault,
          );
          expect(verification, contains('VERIFY_OK'));
        }),
      );

      test(
        'Full Cycle',
        skip: enabled
            ? false
            : 'Set ${profile.optInVariable}=1 to use provider allowance',
        timeout: const Timeout(Duration(minutes: 10)),
        () => _withRuntime(profile, (run, directory) async {
          const marker = 'full-cycle.txt';
          final plan = await run(
            'plan',
            'Plan creation of $marker containing exactly FULL_CYCLE. Reply '
                'with a one-sentence plan only; do not edit files.',
            policy: WorkerExecutionPolicy.providerDefault,
          );
          final implementation = await run(
            'implement',
            'Implement this plan: $plan. Create $marker containing exactly '
                'FULL_CYCLE. Reply with exactly IMPLEMENTED.',
          );
          expect(implementation, contains('IMPLEMENTED'));
          final verification = await run(
            'verify',
            'Read $marker. If its entire content is FULL_CYCLE, reply exactly '
                'FULL_CYCLE_OK; otherwise reply FULL_CYCLE_FAILED.',
            policy: WorkerExecutionPolicy.providerDefault,
          );
          expect(verification, contains('FULL_CYCLE_OK'));
        }),
      );
    });
  }
}

typedef _AssignmentScenario = Future<void> Function(
  Future<String> Function(
    String step,
    String prompt, {
    WorkerExecutionPolicy policy,
  }) run,
  Directory threadDirectory,
);

Future<void> _withRuntime(
  _Profile profile,
  _AssignmentScenario scenario,
) async {
  final root = _repositoryRoot();
  final profileFile = File('${root.path}/${profile.profilePath}');
  final bytes = await profileFile.readAsBytes();
  final profileJson =
      Map<String, Object?>.from(jsonDecode(utf8.decode(bytes)) as Map);
  final tool = Map<String, Object?>.from(profileJson['providerTool'] as Map);
  final digest = sha256.convert(bytes).toString();
  final admission = ToolProfileReleaseAdmission(
    profile: profileJson,
    profileDefinitionId: profile.definitionId,
    releaseVersion: profileJson['releaseVersion'] as int,
    logicalWorkerTypeId: profile.workerTypeId,
    providerToolName: tool['name'] as String,
    payloadDigest: digest,
    channel: 'stable',
  );
  final temp = await Directory.systemTemp.createTemp('assignment-acceptance-');
  try {
    final state = await Directory('${temp.path}/state').create();
    final directory = await Directory('${temp.path}/thread').create();
    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: Platform.environment['DART_EXECUTABLE'] ??
          Platform.resolvedExecutable,
      engineArgumentsPrefix: [
        '${root.path}/engines/cli_worker/bin/conclave_cli_worker.dart',
      ],
    );
    var sequence = 0;
    Future<String> run(
      String step,
      String prompt, {
      WorkerExecutionPolicy policy = WorkerExecutionPolicy.restricted,
    }) async {
      sequence++;
      try {
        final result = await supervisor.execute(
          admission,
          profileFile: profileFile,
          stateDirectory: state,
          workingDirectory: directory,
          workerId: profile.workerTypeId,
          maxConcurrentAssignments: 1,
          assignmentId: '${profile.workerTypeId}-$step-$sequence',
          prompt: prompt,
          timeout: const Duration(minutes: 3),
          executionPolicy: policy,
        );
        return result.output;
      } on CliWorkerEngineProbeException catch (error) {
        final diagnosticsDirectory =
            Platform.environment['CONCLAVE_PROFILE_ACCEPTANCE_DIAGNOSTICS_DIR'];
        if (diagnosticsDirectory != null &&
            diagnosticsDirectory.isNotEmpty &&
            error.localDiagnostics != null) {
          final directory = Directory(diagnosticsDirectory);
          await directory.create(recursive: true);
          await File(
            '${directory.path}/${profile.workerTypeId}-$step-$sequence.stderr',
          ).writeAsString(error.localDiagnostics!);
        }
        rethrow;
      }
    }

    await scenario(run, directory);
    await supervisor.shutdown();
  } finally {
    await temp.delete(recursive: true);
  }
}

Directory _repositoryRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/engines/cli_worker/bin/conclave_cli_worker.dart')
        .existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate the Conclave repository root.');
    }
    current = parent;
  }
}

final class _Profile {
  const _Profile({
    required this.definitionId,
    required this.workerTypeId,
    required this.profilePath,
    required this.optInVariable,
  });

  final String definitionId;
  final String workerTypeId;
  final String profilePath;
  final String optInVariable;
}

const _profiles = <_Profile>[
  _Profile(
    definitionId: 'chatgpt-codex',
    workerTypeId: 'chatgpt',
    profilePath: 'packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
    optInVariable: 'CONCLAVE_TEST_REAL_PROFILE_CHATGPT',
  ),
  _Profile(
    definitionId: 'gemini-antigravity',
    workerTypeId: 'gemini',
    profilePath:
        'packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
    optInVariable: 'CONCLAVE_TEST_REAL_PROFILE_GEMINI',
  ),
];
