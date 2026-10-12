import 'dart:convert';
import 'dart:io';

import 'package:conclave_profile_lab/controllers/profile_lab_controller.dart';
import 'package:conclave_profile_lab/profile_lab_paths.dart';
import 'package:conclave_profile_lab/profile_lab_session_store.dart';
import 'package:conclave_profile_lab/profile_lab_test_sandbox.dart';
import 'package:conclave_profile_lab/utils/profile_domain_diff.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late ProfileLabPaths paths;
  late ProfileLabController controller;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('profile_lab_integration_');
    paths = ProfileLabPaths(homeDirectory: tempDir.path);
    await paths.ensureDirectoriesExist();
    controller = ProfileLabController(
      paths: paths,
      sessionStore: ProfileLabSessionStore.inMemoryForTesting(paths),
    );
    await controller.initialize();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  test('local candidate edit, save, and digest-bound evidence state', () async {
    await controller.createNewDraft(
      profileDefinitionId: 'integration-profile',
      workerTypeId: 'integration-worker',
      providerToolName: 'integration-cli',
    );
    final originalDigest = controller.currentDraft!.payloadDigest;
    final payload =
        jsonDecode(controller.currentJsonText) as Map<String, dynamic>;
    (payload['execution'] as Map<String, dynamic>)['arguments'] = [
      'run',
      '--json',
      '{{prompt}}',
    ];
    controller.updateJsonText(jsonEncode(payload));
    expect(controller.testResultMatchesDraft, isFalse);
    await controller.saveCurrentDraft();
    expect(controller.isDirty, isFalse);
    expect(controller.currentDraft!.payloadDigest, isNot(originalDigest));
  });

  test('domain comparison exposes provider and security-sensitive changes', () {
    final first = <String, Object?>{
      'providerTool': {'name': 'one'},
      'environment': {
        'passthrough': ['PATH']
      },
    };
    final second = <String, Object?>{
      'providerTool': {'name': 'two'},
      'environment': {
        'passthrough': ['PATH', 'HOME']
      },
    };
    final groups = ProfileDomainDiffCalculator.computeDiff(first, second);
    expect(groups.where((group) => group.hasChanges), isNotEmpty);
  });

  test('test ladder returns detailed stages and leaves scratch space clean',
      () async {
    await controller.createNewDraft(
      profileDefinitionId: 'ladder-profile',
      workerTypeId: 'ladder-worker',
      providerToolName: 'fixture-provider',
    );
    final sandbox = ProfileLabTestSandbox(
      sandboxRoot: paths.sandboxDirectory,
      engineExecutable: File('${tempDir.path}/missing-engine'),
    );
    final candidate = LocalDraftProfileCandidate.fromProfileMap(
      controller.currentDraft!.profile,
    );

    final result = await sandbox.executeTestLadder(candidate: candidate);

    expect(result.stages, isNotEmpty);
    expect(result.stages.first.stageId, 'schema');
    expect(result.stages.first.durationMs, greaterThanOrEqualTo(0));
    expect(await paths.sandboxDirectory.list().toList(), isEmpty);
  });
}
