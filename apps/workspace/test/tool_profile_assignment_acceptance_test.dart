import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/cli_worker_engine_supervisor.dart';
import 'package:conclave_workspace/tool_profile_release_verifier.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/repository_root.dart';

void main() {
  for (final profile in _profiles) {
    final profileJson = _loadProfileJson(profile);
    for (final effort in ['low', 'high']) {
      final selection = _selectModelForEffort(profileJson, effort);
      test('live normalized selection ${profile.workerTypeId} $effort',
          skip: Platform.environment[profile.optInVariable] == '1'
              ? false
              : 'Set ${profile.optInVariable}=1 to use provider allowance',
          timeout: const Timeout(Duration(minutes: 5)), () async {
        await _withRuntime(profile, (run, directory) async {
          final response =
              await run('selection', 'Reply with exactly SELECTION_OK.');
          expect(response, contains('SELECTION_OK'));
          final snapshots = await Directory(
                  '${directory.parent.path}/state/execution-selections')
              .list()
              .where((entry) =>
                  entry.path.endsWith('.json') &&
                  !entry.path.endsWith('.completion.json'))
              .toList();
          expect(snapshots, hasLength(1));
          final snapshot =
              jsonDecode(await File(snapshots.single.path).readAsString())
                  as Map;
          expect(snapshot['modelId'], selection.modelId);
          expect(snapshot['effort'], effort);
          expect(
            snapshot['resolvedNativeModelId'],
            selection.resolvedNativeModelId,
          );
          expect(
              snapshot['catalogRevision'], matches(RegExp(r'^[a-f0-9]{64}$')));
        }, modelId: selection.modelId, effort: effort);
      });
    }
  }
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
  _AssignmentScenario scenario, {
  String? modelId,
  String? effort,
}) async {
  final root = repositoryRoot;
  final profileFile = File('$root/${profile.profilePath}');
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
  final supervisor = CliWorkerEngineSupervisor(
    engineExecutable:
        Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
    engineArgumentsPrefix: [
      '$root/engines/cli_worker/bin/conclave_cli_worker.dart',
    ],
  );
  try {
    final state = await Directory('${temp.path}/state').create();
    final directory = await Directory('${temp.path}/thread').create();
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
          model: modelId,
          reasoningEffort: effort,
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
  } finally {
    await supervisor.shutdown();
    await temp.delete(recursive: true);
  }
}

Map<String, Object?> _loadProfileJson(_Profile profile) {
  final root = repositoryRoot;
  final profileFile = File('$root/${profile.profilePath}');
  return Map<String, Object?>.from(
    jsonDecode(profileFile.readAsStringSync()) as Map,
  );
}

({String modelId, String resolvedNativeModelId}) _selectModelForEffort(
  Map<String, Object?> profileJson,
  String effort,
) {
  final model = Map<String, Object?>.from(profileJson['model'] as Map);
  final selectionMapping = model['selectionMapping'];
  if (selectionMapping is Map) {
    final models = (selectionMapping['models'] as List).cast<Map>();
    for (final entry in models) {
      final modelId = entry['id'] as String;
      final variants = (entry['variants'] as List).cast<Map>();
      for (final variant in variants) {
        if (variant['effort'] == effort) {
          return (
            modelId: modelId,
            resolvedNativeModelId: variant['nativeId'] as String,
          );
        }
      }
    }
  }
  final discovery = model['discovery'];
  if (discovery is Map && discovery['effortVariants'] is Map) {
    // The Profile lists no models; efforts come from the installed CLI. The
    // opt-in live run uses a model known to expose every tested effort.
    const modelId = 'gemini-3.8-flash';
    final separator = (discovery['effortVariants'] as Map)['separator'];
    return (
      modelId: modelId,
      resolvedNativeModelId: '$modelId$separator$effort',
    );
  }
  final catalog = model['catalog'];
  if (catalog is List && catalog.isNotEmpty) {
    for (final entry in catalog.cast<Map>()) {
      final efforts =
          (entry['supportedReasoningEfforts'] as List?)?.cast<String>() ??
              const <String>[];
      if (efforts.isEmpty || efforts.contains(effort)) {
        final modelId = entry['id'] as String;
        return (modelId: modelId, resolvedNativeModelId: modelId);
      }
    }
  }
  final allowlist = (model['allowlist'] as List?)?.cast<String>() ?? const [];
  if (allowlist.isNotEmpty) {
    final modelId = allowlist.first;
    return (modelId: modelId, resolvedNativeModelId: modelId);
  }
  throw StateError('No model supporting effort "$effort" found in Profile.');
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
    optInVariable: 'CONCLAVE_TEST_ASSIGNMENT_PROFILE_CHATGPT',
  ),
  _Profile(
    definitionId: 'gemini-antigravity',
    workerTypeId: 'gemini',
    profilePath:
        'packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
    optInVariable: 'CONCLAVE_TEST_ASSIGNMENT_PROFILE_GEMINI',
  ),
];
