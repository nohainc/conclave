part of 'profile_lab_controller.dart';

mixin _ProfileLabTestOperations on _ProfileLabControllerState {
  Future<void> runTestLadder() async {
    if (currentDraft == null || isTesting) return;

    isTesting = true;
    testStatusMessage = 'Executing Progressive 11-Stage Test Ladder...';
    testLogs.clear();
    activeLadderStages = [];
    lastLadderResult = null;
    notifyListeners();

    final candidate = currentDraft!;

    try {
      engineExecutable ??= await loadBundledCliWorkerEngine(
          enginesDirectory: paths.enginesDirectory);
      if (engineExecutable == null) {
        throw StateError('Generic CLI Worker Engine binary is not available.');
      }

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: paths.sandboxDirectory,
        engineExecutable: engineExecutable!,
        processSupervisor: _processSupervisor,
      );
      _activeTestSandbox = sandbox;

      final result = await sandbox.executeTestLadder(
        candidate: candidate,
        onStageUpdate: (stageId, status, diagnostics) {
          notifyListeners();
        },
        onLog: (level, message) {
          testLogs.add(TestExecutionLog(
            timestamp: DateTime.now(),
            level: level,
            message: message,
          ));
          notifyListeners();
        },
      );

      lastLadderResult = result;
      activeLadderStages = result.stages;
      lastTestResult = result.overallResult;
      final passedCount =
          result.stages.where((s) => s.status == 'passed').length;
      testStatusMessage =
          'Test Ladder completed: ${result.overallResult.toUpperCase()} ($passedCount/${result.stages.length} stages passed)';

      final acceptanceEvidence = result.acceptanceEvidence;
      if (acceptanceEvidence != null) {
        await store.saveEvidence(
          profileDefinitionId: candidate.profileDefinitionId,
          payloadDigest: candidate.payloadDigest,
          evidenceRecord: acceptanceEvidence.toJson(),
        );
      }
      await refreshEvidence();
    } catch (e) {
      lastTestResult = 'fail';
      testStatusMessage = 'Ladder execution failed: $e';
      testLogs.add(TestExecutionLog(
        timestamp: DateTime.now(),
        level: 'error',
        message: 'Ladder exception: $e',
      ));
    } finally {
      _activeTestSandbox = null;
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

  /// Loads any active, non-expired Profile Lab session from the dedicated credentials directory.
}
