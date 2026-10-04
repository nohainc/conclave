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
      final workers = await apiClient.fetchWorkerCatalog();
      if (generation != _cloudGeneration) {
        return;
      }
      cloudWorkers = workers.map((worker) => worker.toJson()).toList();
      if (cloudWorkers.isEmpty) {
        selectedCloudWorker = null;
        selectedCloudDefinition = null;
        selectedDefinitionId = null;
        cloudReleases = [];
        selectedCloudRelease = null;
        cloudEvidence = [];
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

  /// Selects a Worker from the Cloud catalog and fetches its definition & releases.
  Future<void> selectWorker(Map<String, dynamic> worker) async {
    final generation = _cloudGeneration;
    selectedCloudWorker = worker;
    selectedDefinitionId = worker['profileDefinitionId'] as String?;
    cloudReleases = [];
    selectedCloudRelease = null;
    cloudEvidence = [];
    selectedCloudDefinition = null;
    definitionsError = null;
    notifyListeners();
    final defId = worker['profileDefinitionId'] as String?;
    if (defId != null && defId.isNotEmpty) {
      selectedDefinitionId = defId;
      try {
        await _refresh('definition:$defId', () async {
          final definition = await apiClient.fetchDefinition(defId);
          if (generation == _cloudGeneration && selectedDefinitionId == defId) {
            selectedCloudDefinition = definition.toJson();
          }
        });
      } catch (e) {
        if (generation == _cloudGeneration && selectedDefinitionId == defId) {
          definitionsError = 'Failed to fetch definition: $e';
        }
      }
      if (generation != _cloudGeneration || selectedDefinitionId != defId) {
        return;
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
      selectedDefinitionId = null;
      selectedCloudDefinition = null;
      cloudReleases = [];
      selectedCloudRelease = null;
    }
    notifyListeners();
  }

  /// Fetches releases for a profile definition.
  @override
  Future<void> fetchCloudReleases([String? profileDefinitionId]) => _refresh(
      'releases:${profileDefinitionId ?? selectedDefinitionId}',
      () => _fetchCloudReleases(profileDefinitionId));

  Future<void> _fetchCloudReleases(String? profileDefinitionId) async {
    final generation = _cloudGeneration;
    final defId = profileDefinitionId ?? selectedDefinitionId;
    if (defId == null) {
      cloudReleases = [];
      selectedCloudRelease = null;
      notifyListeners();
      return;
    }

    releasesError = null;
    try {
      final result = await apiClient.fetchReleases(defId);
      if (generation != _cloudGeneration || selectedDefinitionId != defId) {
        return;
      }
      cloudReleases = result.map((release) => release.toJson()).toList();
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
      if (generation != _cloudGeneration || selectedDefinitionId != defId) {
        return;
      }
      releasesError = 'Failed to fetch releases: $e';
      cloudError = releasesError;
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
          {String? profileDefinitionId, int? version}) =>
      _refresh(
          'evidence:${profileDefinitionId ?? selectedDefinitionId}:${version ?? selectedCloudRelease?['releaseVersion']}',
          () => _fetchCloudEvidence(
              profileDefinitionId: profileDefinitionId, version: version));

  Future<void> _fetchCloudEvidence(
      {String? profileDefinitionId, int? version}) async {
    final generation = _cloudGeneration;
    final defId = profileDefinitionId ?? selectedDefinitionId;
    final ver = version ?? selectedCloudRelease?['releaseVersion'] as int?;
    if (defId == null || ver == null) {
      cloudEvidence = [];
      notifyListeners();
      return;
    }

    evidenceError = null;
    try {
      final result = await apiClient.fetchReleaseEvidence(defId, ver);
      if (generation != _cloudGeneration ||
          selectedDefinitionId != defId ||
          selectedCloudRelease?['releaseVersion'] != ver) {
        return;
      }
      cloudEvidence = result.map((evidence) => evidence.toJson()).toList();
    } catch (e) {
      if (generation != _cloudGeneration ||
          selectedDefinitionId != defId ||
          selectedCloudRelease?['releaseVersion'] != ver) {
        return;
      }
      evidenceError = 'Failed to fetch evidence: $e';
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
  Future<void> fetchCloudAudit({bool? definitionOnly}) => _refresh(
      'audit:${(definitionOnly ?? auditFilterCurrentDefinition) ? selectedDefinitionId : null}',
      () => _fetchCloudAudit(definitionOnly: definitionOnly));

  Future<void> _fetchCloudAudit({bool? definitionOnly}) async {
    if (definitionOnly != null) {
      auditFilterCurrentDefinition = definitionOnly;
    }
    final generation = _cloudGeneration;
    final defId = auditFilterCurrentDefinition ? selectedDefinitionId : null;
    auditError = null;

    try {
      final result = await apiClient.fetchAudit(defId);
      if (generation != _cloudGeneration ||
          defId !=
              (auditFilterCurrentDefinition ? selectedDefinitionId : null)) {
        return;
      }
      cloudAuditEvents = result.map((event) => event.toJson()).toList();
    } catch (e) {
      if (generation != _cloudGeneration ||
          defId !=
              (auditFilterCurrentDefinition ? selectedDefinitionId : null)) {
        return;
      }
      auditError = 'Failed to fetch audit: $e';
      cloudError = auditError;
    }
    notifyListeners();
  }

  /// Executes channel pointer rollback.
  Future<void> rollbackChannelPointer(
          {required String channel,
          required int targetReleaseVersion,
          String? reason}) =>
      _refresh(
          'rollback',
          () => _rollbackChannelPointer(
              channel: channel,
              targetReleaseVersion: targetReleaseVersion,
              reason: reason));

  Future<void> _rollbackChannelPointer({
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
  Future<void> promoteCloudRelease(
          {required int releaseVersion,
          required String channel,
          String? acceptanceEvidenceId}) =>
      _refresh(
          'promote',
          () => _promoteCloudRelease(
              releaseVersion: releaseVersion,
              channel: channel,
              acceptanceEvidenceId: acceptanceEvidenceId));

  Future<void> _promoteCloudRelease({
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
  Future<void> revokeCloudRelease(
          {required int releaseVersion, required String reason}) =>
      _refresh(
          'revoke',
          () => _revokeCloudRelease(
              releaseVersion: releaseVersion, reason: reason));

  Future<void> _revokeCloudRelease({
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
  Future<void> publishCurrentDraft() =>
      _refresh('publish', _publishCurrentDraft);

  Future<void> _publishCurrentDraft() async {
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
