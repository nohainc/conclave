part of 'profile_lab_controller.dart';

mixin _ProfileLabAiOperations on _ProfileLabControllerState {
  final ProfileLabModelProposalService _modelProposalService =
      const ProfileLabModelProposalService();

  Future<List<ProfileLabAiModelOption>> loadAvailableAiModels() async {
    if (currentSession == null || currentSession!.isExpired) {
      throw StateError(
          'Sign in to Cloud to load trusted current Worker Profiles.');
    }
    final models = await _modelProposalService.loadAvailableModels(
      apiClient: apiClient,
      trustPolicy: profileLabReleaseTrustPolicy(),
      discoverModels: (profile) async {
        final engine = engineExecutable;
        if (engine == null) {
          throw StateError('Generic Worker Engine is unavailable.');
        }
        return ProfileLabTestSandbox(
          sandboxRoot: paths.sandboxDirectory,
          engineExecutable: engine,
          processSupervisor: _processSupervisor,
          environmentOverrides: sandboxEnvironmentOverrides,
        ).discoverTrustedModels(profile);
      },
    );
    availableAiModels = models;
    aiProposalError = models.isEmpty
        ? 'No trusted current Worker Profile is available for model proposals. '
            'Configure the Profile Lab trust roots and publish a Worker Profile.'
        : null;
    notifyListeners();
    return models;
  }

  Future<Map<String, dynamic>> generateAiDraftProposal({
    required String modelOptionId,
    required String userInstruction,
    required bool dataSharingConfirmed,
    String? reasoningEffort,
  }) async {
    if (isGeneratingAiProposal) {
      throw StateError('A model proposal is already running.');
    }
    if (currentDraft == null || selectedDefinitionId == null) {
      throw StateError(
          'Select a local candidate before generating a proposal.');
    }
    if (jsonValidationError != null) {
      throw StateError(
          'Fix candidate validation errors before requesting a proposal.');
    }
    if (userInstruction.trim().isEmpty) {
      throw ArgumentError.value(userInstruction, 'userInstruction');
    }
    if (!dataSharingConfirmed) {
      throw StateError(
          'Confirm sharing candidate context with the selected model.');
    }

    isGeneratingAiProposal = true;
    aiProposalError = null;
    notifyListeners();
    try {
      // Re-read the current catalog immediately before model execution. A stale
      // menu selection cannot authorize a revoked or replaced Profile.
      final modelOptions = await loadAvailableAiModels();
      final selectedModel = modelOptions
          .where((option) => option.id == modelOptionId)
          .firstOrNull;
      if (selectedModel == null) {
        throw StateError(
          'The selected current Worker Profile is no longer trusted or available.',
        );
      }

      engineExecutable ??= await loadBundledCliWorkerEngine(
        enginesDirectory: paths.enginesDirectory,
      );
      if (engineExecutable == null) {
        throw StateError('Generic CLI Worker Engine binary is not available.');
      }
      final draftJson = jsonDecode(currentJsonText);
      if (draftJson is! Map<String, dynamic>) {
        throw const FormatException('Current candidate must be a JSON object.');
      }
      EngineProfile.parse(utf8.encode(canonicalJson(draftJson)));

      final sandbox = ProfileLabTestSandbox(
        sandboxRoot: paths.sandboxDirectory,
        engineExecutable: engineExecutable!,
        processSupervisor: _processSupervisor,
      );
      _activeAiSandbox = sandbox;
      final diagnostics = <Map<String, dynamic>>[];
      if (lastLadderResult != null) {
        diagnostics.addAll(lastLadderResult!.stages.take(12).map((stage) => {
              'stage': stage.stageId,
              'status': stage.status,
              'diagnostics': stage.diagnostics,
            }));
      }
      final proposal = await _modelProposalService.proposeDraft(
        sandbox: sandbox,
        modelOption: selectedModel,
        reasoningEffort: reasoningEffort,
        currentDraft: Map<String, dynamic>.from(draftJson),
        userInstruction: userInstruction,
        testDiagnostics: diagnostics,
      );
      return proposal;
    } catch (error) {
      aiProposalError = error.toString();
      rethrow;
    } finally {
      _activeAiSandbox = null;
      isGeneratingAiProposal = false;
      notifyListeners();
    }
  }

  Future<void> cancelAiDraftProposal() async {
    await _activeAiSandbox?.cancelCurrentTest();
  }
}
