part of 'profile_lab_controller.dart';

mixin _ProfileLabCloudOperations on _ProfileLabControllerState {
  // --- Cloud Profile Admin Operations ---

  /// Fetches dynamic Worker catalog from Cloud.
  @override
  Future<void> fetchCloudCatalog() => _refresh('catalog', _fetchCloudCatalog);

  Future<void> _fetchCloudCatalog() async {
    final generation = _cloudGeneration;
    workerCatalogError = null;
    workerCatalogUnauthorized = false;
    cloudError = null;
    notifyListeners();

    try {
      final workers = await apiClient.fetchV9WorkerProfiles();
      if (generation != _cloudGeneration) {
        return;
      }
      cloudWorkers = workers.map((worker) => worker.toJson()).toList();
      if (cloudWorkers.isEmpty) {
        selectedCloudWorker = null;
        selectedCloudDefinition = null;
        selectedDefinitionId = null;
      }
      if (selectedCloudWorker != null) {
        final match = cloudWorkers.firstWhere(
          (w) => w['workerTypeId'] == selectedCloudWorker!['workerTypeId'],
          orElse: () => cloudWorkers.isNotEmpty
              ? cloudWorkers.first
              : const <String, dynamic>{},
        );
        if (match.isNotEmpty) {
          unawaited(selectWorker(match));
        }
      } else if (cloudWorkers.isNotEmpty) {
        unawaited(selectWorker(cloudWorkers.first));
      }
    } catch (e) {
      if (generation != _cloudGeneration) {
        return;
      }
      workerCatalogError = 'Failed to load Cloud catalog: $e';
      workerCatalogUnauthorized = e is ProfileAdminUnauthorizedException;
      cloudError = workerCatalogError;
      _loaded.remove('catalog');
    } finally {
      notifyListeners();
    }
  }

  /// Selects a Worker and loads its one current published Profile.
  Future<void> selectWorker(Map<String, dynamic> worker) async {
    final generation = _cloudGeneration;
    currentDraft = null;
    currentMetadata = null;
    currentJsonText = '';
    currentEvidence = [];
    isDirty = false;
    jsonValidationError = null;
    resetDraftTestState();
    currentCloudProfileSnapshot = null;
    currentProfileRevision = 0;
    currentProfileDigest = null;
    candidateCloudValidatedDigest = null;
    selectedCloudWorker = worker;
    selectedDefinitionId = worker['profileDefinitionId'] as String?;
    selectedCloudDefinition = null;
    definitionsError = null;
    notifyListeners();
    final workerTypeId = worker['workerTypeId'] as String?;
    if (workerTypeId == null || workerTypeId.isEmpty) return;
    try {
      final snapshot = await apiClient.fetchCurrentWorkerProfile(workerTypeId);
      if (generation != _cloudGeneration ||
          selectedCloudWorker?['workerTypeId'] != workerTypeId) {
        return;
      }
      currentCloudProfileSnapshot = snapshot;
      currentProfileRevision = (snapshot['revision'] as num?)?.toInt() ?? 0;
      currentProfileDigest = snapshot['digest'] as String?;
      final profile = snapshot['profile'];
      if (profile is Map) {
        final profileMap = Map<String, dynamic>.from(profile);
        selectedDefinitionId = profileMap['profileDefinitionId'] as String?;
        final provider = profileMap['providerTool'];
        selectedCloudDefinition = {
          'profileDefinitionId': selectedDefinitionId,
          'displayName': worker['displayName'],
          'providerToolName': provider is Map ? provider['name'] : null,
          'status': 'current',
        };
      }
      await loadProfileFromFolder();
      await discoverInstalledProviders();
      notifyListeners();
    } on ProfileAdminNotFoundException {
      selectedCloudDefinition = {
        'displayName': worker['displayName'],
        'providerToolName': worker['providerToolName'],
      };
      definitionsError = null;
      await loadProfileFromFolder();
      await discoverInstalledProviders();
      notifyListeners();
    } catch (e) {
      definitionsError = 'Failed to fetch current Worker Profile: $e';
      await loadProfileFromFolder();
      notifyListeners();
    }
  }

  Future<void> _adoptPublishedSnapshot(
    Map<String, dynamic> snapshot, {
    required String notes,
  }) async {
    currentCloudProfileSnapshot = snapshot;
    currentProfileRevision =
        (snapshot['revision'] as num?)?.toInt() ?? currentProfileRevision + 1;
    currentProfileDigest = snapshot['digest'] as String?;
    if (selectedCloudWorker != null) {
      selectedCloudWorker = {
        ...selectedCloudWorker!,
        'currentRevision': currentProfileRevision,
        'currentDigest': currentProfileDigest,
      };
    }
    final profile = snapshot['profile'];
    if (profile is! Map || selectedDefinitionId == null) {
      notifyListeners();
      return;
    }
    final profileMap = Map<String, Object?>.from(profile);
    currentDraft = await store.saveDraft(
      profileDefinitionId: selectedDefinitionId!,
      profileJson: profileMap,
      notes: notes,
    );
    currentMetadata = await store.loadDraftMetadata(selectedDefinitionId!);
    currentJsonText = const JsonEncoder.withIndent('  ').convert(profileMap);
    isDirty = false;
    jsonValidationError = null;
    jsonValidationLocation = null;
    resetDraftTestState();
    await refreshEvidence();
    notifyListeners();
  }

  /// Requests Cloud publication of the current local candidate.
  /// Cloud performs the authoritative validation and atomic publication.
  Future<void> publishCurrentDraft() =>
      _refresh('publish', _publishCurrentDraft);

  Future<void> _publishCurrentDraft() async {
    if (selectedDefinitionId == null || currentDraft == null) return;
    try {
      final draft = currentDraft!;
      if (!canPublish) {
        throw StateError(
          'Profile Lab authorization is required to publish.',
        );
      }
      final evidence = _publicationEvidenceFor(draft);
      if (evidence == null) {
        throw StateError(
          'Run the complete local Test Ladder for this exact candidate before publishing.',
        );
      }
      final profile = Map<String, dynamic>.from(draft.profile);
      final validation = await apiClient.validateWorkerProfileCandidate(
        workerTypeId: selectedCloudWorker!['workerTypeId'] as String,
        profile: profile,
        candidateDigest: draft.payloadDigest,
        evidence: evidence,
      );
      candidateCloudValidatedDigest =
          validation['digest'] as String? ?? draft.payloadDigest;
      final snapshot = await apiClient.publishWorkerProfile(
        workerTypeId: selectedCloudWorker!['workerTypeId'] as String,
        expectedRevision: currentProfileRevision,
        profile: profile,
        candidateDigest: draft.payloadDigest,
        evidence: evidence,
      );
      await _adoptPublishedSnapshot(snapshot,
          notes: 'Published Profile candidate');
    } catch (e) {
      cloudError = 'Publish failed: $e';
      rethrow;
    }
  }

  /// Performs Cloud's candidate revalidation without changing the current
  /// Worker Profile. The digest is cleared whenever the editor changes.
  Future<void> validateCurrentDraft() =>
      _refresh('validate-candidate', _validateCurrentDraft);

  Future<void> _validateCurrentDraft() async {
    final draft = currentDraft;
    final workerTypeId = selectedCloudWorker?['workerTypeId'] as String?;
    if (draft == null || workerTypeId == null) return;
    if (isDirty || jsonValidationError != null) {
      throw StateError('Save a valid local candidate before Cloud validation.');
    }
    final evidence = _publicationEvidenceFor(draft);
    final response = await apiClient.validateWorkerProfileCandidate(
      workerTypeId: workerTypeId,
      profile: Map<String, dynamic>.from(draft.profile),
      candidateDigest: draft.payloadDigest,
      evidence: evidence,
    );
    candidateCloudValidatedDigest =
        response['digest'] as String? ?? draft.payloadDigest;
    cloudError = null;
    notifyListeners();
  }

  Map<String, Object?>? _publicationEvidenceFor(
    LocalDraftProfileCandidate draft,
  ) {
    final expectedScenarios = cloudAcceptanceScenarioStatuses(draft.profile);
    for (final item in currentEvidence) {
      if (item['formatVersion'] == 1 &&
          item['workerTypeId'] == draft.logicalWorkerTypeId &&
          item['candidateDigest'] == draft.payloadDigest &&
          item['scenarios'] is Map &&
          Map<String, Object?>.from(item['scenarios'] as Map).length ==
              expectedScenarios.length &&
          expectedScenarios.entries.every(
            (entry) => (item['scenarios'] as Map)[entry.key] == entry.value,
          )) {
        return Map<String, Object?>.from(item);
      }
    }
    return null;
  }
}
