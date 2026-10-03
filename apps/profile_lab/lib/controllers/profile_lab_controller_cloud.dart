part of 'profile_lab_controller.dart';

mixin _ProfileLabCloudOperations on _ProfileLabControllerState {
  // --- Cloud Profile Admin Operations ---

  /// Fetches dynamic Worker catalog from Cloud.
  @override
  Future<void> fetchCloudCatalog() async {
    isLoadingCloud = true;
    cloudError = null;
    notifyListeners();

    try {
      final workers = await apiClient.fetchWorkerCatalog();
      cloudWorkers = workers.map((worker) => worker.toJson()).toList();
      await discoverInstalledProviders();
      if (selectedCloudWorker != null) {
        final match = cloudWorkers.firstWhere(
          (w) => w['workerTypeId'] == selectedCloudWorker!['workerTypeId'],
          orElse: () => cloudWorkers.isNotEmpty
              ? cloudWorkers.first
              : const <String, dynamic>{},
        );
        if (match.isNotEmpty) {
          await selectWorker(match);
        }
      } else if (cloudWorkers.isNotEmpty) {
        await selectWorker(cloudWorkers.first);
      }
    } catch (e) {
      cloudError = 'Failed to load Cloud catalog: $e';
    } finally {
      isLoadingCloud = false;
      notifyListeners();
    }
  }

  /// Selects a Worker from the Cloud catalog and fetches its definition & releases.
  Future<void> selectWorker(Map<String, dynamic> worker) async {
    selectedCloudWorker = worker;
    final defId = worker['profileDefinitionId'] as String?;
    if (defId != null && defId.isNotEmpty) {
      selectedDefinitionId = defId;
      try {
        selectedCloudDefinition =
            (await apiClient.fetchDefinition(defId)).toJson();
      } catch (_) {
        selectedCloudDefinition = null;
      }

      // Check if a local draft exists for this definition
      if (draftDefinitionIds.contains(defId)) {
        await selectDraft(defId);
      }

      await fetchCloudReleases(defId);
      if (auditFilterCurrentDefinition) {
        await fetchCloudAudit(definitionOnly: true);
      }
    } else {
      selectedCloudDefinition = null;
      cloudReleases = [];
      selectedCloudRelease = null;
    }
    notifyListeners();
  }

  /// Fetches releases for a profile definition.
  @override
  Future<void> fetchCloudReleases([String? profileDefinitionId]) async {
    final defId = profileDefinitionId ?? selectedDefinitionId;
    if (defId == null) {
      cloudReleases = [];
      selectedCloudRelease = null;
      notifyListeners();
      return;
    }

    try {
      cloudReleases = (await apiClient.fetchReleases(defId))
          .map((release) => release.toJson())
          .toList();
      if (cloudReleases.isNotEmpty) {
        selectedCloudRelease = cloudReleases.first;
        final version = selectedCloudRelease!['releaseVersion'] as int?;
        if (version != null) {
          await fetchCloudEvidence(
              profileDefinitionId: defId, version: version);
        }
      } else {
        selectedCloudRelease = null;
        cloudEvidence = [];
      }
    } catch (e) {
      cloudError = 'Failed to fetch releases: $e';
    }
    await discoverInstalledProviders();
    notifyListeners();
  }

  /// Selects a release and fetches its acceptance evidence.
  Future<void> selectCloudRelease(Map<String, dynamic> release) async {
    selectedCloudRelease = release;
    final defId = selectedDefinitionId;
    final version = release['releaseVersion'] as int?;
    if (defId != null && version != null) {
      await fetchCloudEvidence(profileDefinitionId: defId, version: version);
    }
    notifyListeners();
  }

  /// Fetches Cloud acceptance evidence for a release.
  @override
  Future<void> fetchCloudEvidence(
      {String? profileDefinitionId, int? version}) async {
    final defId = profileDefinitionId ?? selectedDefinitionId;
    final ver = version ?? selectedCloudRelease?['releaseVersion'] as int?;
    if (defId == null || ver == null) {
      cloudEvidence = [];
      notifyListeners();
      return;
    }

    try {
      cloudEvidence = (await apiClient.fetchReleaseEvidence(defId, ver))
          .map((evidence) => evidence.toJson())
          .toList();
    } catch (_) {
      cloudEvidence = [];
    }
    notifyListeners();
  }

  /// Stores a complete local sandbox contract as immutable Cloud evidence for
  /// the published release with the exact same identity and digest.
  Future<Map<String, dynamic>> submitCloudAcceptanceEvidence(
    Map<String, Object?> evidence,
  ) async {
    final draft = currentDraft;
    final definitionId = selectedDefinitionId;
    if (draft == null || definitionId == null) {
      throw StateError('Select a Profile Definition and release first.');
    }
    if (!ToolProfileAcceptanceEvidence.hasCloudContractShape(
      evidence,
      profile: draft.profile,
    )) {
      throw StateError(
          'Only complete sandbox acceptance evidence can be submitted.');
    }
    if (evidence['profileDefinitionId'] != draft.profileDefinitionId ||
        evidence['releaseVersion'] != draft.releaseVersion ||
        evidence['profileDigest'] != draft.payloadDigest) {
      throw StateError('Evidence must match the selected Profile payload.');
    }
    Map<String, dynamic>? publishedRelease;
    for (final release in cloudReleases) {
      if (release['releaseVersion'] == draft.releaseVersion &&
          release['payloadDigest'] == draft.payloadDigest &&
          release['publishedAt'] is String) {
        publishedRelease = release;
        break;
      }
    }
    if (publishedRelease == null) {
      throw StateError(
        'Publish this exact Profile payload before submitting its evidence.',
      );
    }

    isSubmittingCloudEvidence = true;
    notifyListeners();
    try {
      final result = await apiClient.submitReleaseEvidence(
        profileDefinitionId: definitionId,
        releaseVersion: draft.releaseVersion,
        evidence: evidence,
      );
      await fetchCloudEvidence(
        profileDefinitionId: definitionId,
        version: draft.releaseVersion,
      );
      await fetchCloudAudit();
      return result;
    } catch (e) {
      cloudError = 'Cloud evidence submission failed: $e';
      rethrow;
    } finally {
      isSubmittingCloudEvidence = false;
      notifyListeners();
    }
  }

  /// Fetches audit events globally or scoped to the current definition.
  @override
  Future<void> fetchCloudAudit({bool? definitionOnly}) async {
    if (definitionOnly != null) {
      auditFilterCurrentDefinition = definitionOnly;
    }
    final defId = auditFilterCurrentDefinition ? selectedDefinitionId : null;

    try {
      cloudAuditEvents = (await apiClient.fetchAudit(defId))
          .map((event) => event.toJson())
          .toList();
    } catch (e) {
      cloudError = 'Failed to fetch audit: $e';
    }
    notifyListeners();
  }

  /// Executes channel pointer rollback.
  Future<void> rollbackChannelPointer({
    required String channel,
    required int targetReleaseVersion,
    String? reason,
  }) async {
    if (selectedDefinitionId == null) return;
    try {
      await apiClient.rollbackChannel(
        profileDefinitionId: selectedDefinitionId!,
        channel: channel,
        targetReleaseVersion: targetReleaseVersion,
        reason: reason,
      );
      await fetchCloudReleases();
      await fetchCloudAudit();
    } catch (e) {
      cloudError = 'Rollback failed: $e';
      rethrow;
    }
  }

  /// Promotes a release. Stable promotion requires a separately stored Cloud
  /// evidence record and sends only its immutable identifier.
  Future<void> promoteCloudRelease({
    required int releaseVersion,
    required String channel,
    String? acceptanceEvidenceId,
  }) async {
    final normalizedChannel = channel.toLowerCase();
    if (normalizedChannel == 'stable' &&
        (acceptanceEvidenceId == null || acceptanceEvidenceId.trim().isEmpty)) {
      throw StateError(
        'Stable promotion requires a qualifying Cloud evidence record.',
      );
    }
    if (selectedDefinitionId == null) return;
    try {
      await apiClient.promoteRelease(
        profileDefinitionId: selectedDefinitionId!,
        releaseVersion: releaseVersion,
        channel: normalizedChannel,
        acceptanceEvidenceId: acceptanceEvidenceId,
      );
      await fetchCloudReleases();
      await fetchCloudAudit();
    } catch (e) {
      cloudError = 'Promotion failed: $e';
      rethrow;
    }
  }

  /// Revokes a release version permanently for security/safety reasons.
  Future<void> revokeCloudRelease({
    required int releaseVersion,
    required String reason,
  }) async {
    if (selectedDefinitionId == null) return;
    try {
      await apiClient.changeLifecycle(
        profileDefinitionId: selectedDefinitionId!,
        releaseVersion: releaseVersion,
        lifecycle: 'revoked',
        reason: reason,
      );
      await fetchCloudReleases(selectedDefinitionId!);
      await fetchCloudAudit();
    } catch (e) {
      cloudError = 'Revocation failed: $e';
      rethrow;
    }
  }

  /// Requests Cloud publication of the current draft.
  /// Signing occurs in the controlled Cloud signing service; Profile Lab does
  /// not hold or manage private keys.
  Future<void> publishCurrentDraft() async {
    if (selectedDefinitionId == null || currentDraft == null) return;
    try {
      final draft = currentDraft!;
      Map<String, Object?>? localQualification;
      for (final item in currentEvidence) {
        if (ToolProfileAcceptanceEvidence.hasCloudContractShape(
              item,
              profile: draft.profile,
            ) &&
            item['profileDefinitionId'] == draft.profileDefinitionId &&
            item['releaseVersion'] == draft.releaseVersion &&
            item['profileDigest'] == draft.payloadDigest) {
          localQualification = item;
          break;
        }
      }
      if (localQualification == null) {
        throw StateError(
          'Run the complete local Test Ladder for this exact draft before publishing.',
        );
      }

      final preflight = await apiClient.checkSigningPreflight();
      if (!preflight.ready) {
        throw StateError(
          'Cloud release signing preflight failed: '
          '${preflight.issues.isNotEmpty ? preflight.issues.join(', ') : 'signer configuration is invalid'}',
        );
      }
      final qualification = await apiClient.submitLocalQualification(
        profileDefinitionId: draft.profileDefinitionId,
        releaseVersion: draft.releaseVersion,
        evidence: localQualification,
      );
      final qualificationEvidenceId =
          qualification['qualificationEvidenceId'] as String?;
      if (qualificationEvidenceId == null ||
          qualificationEvidenceId.trim().isEmpty) {
        throw StateError('Cloud did not return a qualification evidence ID.');
      }
      await apiClient.publishRelease(
        profileDefinitionId: draft.profileDefinitionId,
        releaseVersion: draft.releaseVersion,
        qualificationEvidenceId: qualificationEvidenceId,
      );
      await fetchCloudReleases(draft.profileDefinitionId);
      await fetchCloudAudit();
      await refreshDrafts();
    } catch (e) {
      cloudError = 'Publish failed: $e';
      rethrow;
    }
  }

  /// Atomically registers an approved logical Worker and its initial Profile definition in Cloud.
  Future<void> createWorkerCatalogEntry({
    required String workerTypeId,
    required String profileDefinitionId,
    required String displayName,
    required String description,
    required String providerToolName,
    required String releaseStage,
    required List<String> capabilities,
    required int sortOrder,
  }) async {
    final client = apiClient;
    await client.createWorker(
      workerTypeId: workerTypeId,
      profileDefinitionId: profileDefinitionId,
      displayName: displayName,
      description: description,
      providerToolName: providerToolName,
      releaseStage: releaseStage,
      capabilities: capabilities,
      sortOrder: sortOrder,
    );
    await fetchCloudCatalog();
  }
}
