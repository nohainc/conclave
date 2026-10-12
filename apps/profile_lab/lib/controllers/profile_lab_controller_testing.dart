part of 'profile_lab_controller.dart';

mixin _ProfileLabTestOperations on _ProfileLabControllerState {
  Future<void> runActivityMappingTest() async {
    final candidate = currentDraft;
    if (candidate == null ||
        isTesting ||
        isDirty ||
        jsonValidationError != null ||
        isPublishing) {
      return;
    }
    try {
      EngineProfile.parse(utf8.encode(canonicalJson(candidate.profile)));
      lastActivityMappingReplay =
          replayProfileActivityMappings(candidate.profile);
      testedActivityMappingDigest = candidate.payloadDigest;
    } catch (error) {
      testedActivityMappingDigest = candidate.payloadDigest;
      lastActivityMappingReplay = ProfileActivityMappingReplayResult(
        status: 'failed',
        provider: candidate.providerToolName,
        fixtureName: null,
        events: const [],
        activities: const [],
        message: 'Profile mapping validation failed: $error',
      );
    }
    notifyListeners();
  }

  Future<void> runTestLadder() async {
    if (currentDraft == null ||
        isTesting ||
        isDirty ||
        jsonValidationError != null ||
        isPublishing) {
      return;
    }
    final candidate = currentDraft!;
    lastActivityMappingReplay =
        replayProfileActivityMappings(candidate.profile);
    testedActivityMappingDigest = candidate.payloadDigest;
    bool isCurrent() =>
        testResultMatchesDraft &&
        testedDraftDigest == candidate.payloadDigest &&
        testedProfileDefinitionId == candidate.profileDefinitionId;
    testedDraftDigest = candidate.payloadDigest;
    testedProfileDefinitionId = candidate.profileDefinitionId;
    lastTestResult = null;

    testStartedAt = DateTime.now().toUtc();
    testCompletedAt = null;
    isTesting = true;
    testStatusMessage = 'Running full test…';
    testLogs.clear();
    activeLadderStages = [];
    lastLadderResult = null;
    notifyListeners();

    try {
      engineExecutable ??= await loadBundledCliWorkerEngine(
        enginesDirectory: paths.enginesDirectory,
      );
      if (engineExecutable == null) {
        throw StateError('Generic CLI Worker Engine binary is not available.');
      }

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: paths.sandboxDirectory,
        engineExecutable: engineExecutable!,
        processSupervisor: _processSupervisor,
        environmentOverrides: sandboxEnvironmentOverrides,
      );
      _activeTestSandbox = sandbox;

      final result = await sandbox.executeTestLadder(
        candidate: candidate,
        onStageResult: (stage) {
          if (!isCurrent()) return;
          activeLadderStages = [...activeLadderStages, stage];
          testStatusMessage =
              '${activeLadderStages.length}/12 stages completed';
          notifyListeners();
        },
        onLog: (level, message) {
          if (!isCurrent()) return;
          testLogs.add(
            TestExecutionLog(
              timestamp: DateTime.now(),
              level: level,
              message: message,
            ),
          );
          notifyListeners();
        },
      );

      if (isCurrent()) {
        lastLadderResult = result;
        activeLadderStages = result.stages;
        lastTestResult = result.overallResult;
        final passedCount =
            result.stages.where((s) => s.status == 'passed').length;
        testStatusMessage = '$passedCount/${result.stages.length} passed';
      }

      final publicationEvidence = result.publicationEvidence;
      if (publicationEvidence != null) {
        await store.saveEvidence(
          profileDefinitionId: candidate.profileDefinitionId,
          payloadDigest: candidate.payloadDigest,
          evidenceRecord: publicationEvidence.toJson(),
        );
      }
      await refreshEvidence();
    } catch (e) {
      if (!isCurrent()) return;
      lastTestResult = 'fail';
      testStatusMessage = 'Full test failed: $e';
      testLogs.add(
        TestExecutionLog(
          timestamp: DateTime.now(),
          level: 'error',
          message: 'Ladder exception: $e',
        ),
      );
    } finally {
      _activeTestSandbox = null;
      if (isCurrent()) testCompletedAt = DateTime.now().toUtc();
      isTesting = false;
      notifyListeners();
    }
  }

  /// Requests cancellation of the active Engine assignment and its process tree.
  Future<void> cancelTest() async {
    final cancelled = await _activeTestSandbox?.cancelCurrentTest() ?? false;
    if (cancelled) {
      testStatusMessage =
          'Cancellation requested for the active Engine assignment.';
      notifyListeners();
    }
  }
}
