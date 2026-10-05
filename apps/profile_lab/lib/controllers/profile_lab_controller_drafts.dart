part of 'profile_lab_controller.dart';

mixin _ProfileLabDraftOperations on _ProfileLabControllerState {
  @override
  Future<void> refreshDrafts() async {
    draftDefinitionIds = await store.listDraftDefinitionIds();
    if (selectedDefinitionId != null &&
        draftDefinitionIds.contains(selectedDefinitionId)) {
      await selectDraft(selectedDefinitionId!);
    } else if (draftDefinitionIds.isNotEmpty) {
      await selectDraft(draftDefinitionIds.first);
    } else {
      selectedDefinitionId = null;
      currentDraft = null;
      currentMetadata = null;
      currentJsonText = '';
      currentEvidence = [];
    }
    notifyListeners();
  }

  @override
  Future<void> selectDraft(String profileDefinitionId) async {
    selectedDefinitionId = profileDefinitionId;
    pendingAiProvenance = null;
    currentDraft = await store.loadDraft(profileDefinitionId);
    currentMetadata = await store.loadDraftMetadata(profileDefinitionId);
    baseCloudDigest = null;
    cloudDigest = null;
    cloudDraftPayload = null;
    cloudDraftExists = null;
    cloudDraftVersion = null;
    cloudReleaseLifecycleState = null;
    syncState = DraftSyncState.saved;

    if (currentDraft != null) {
      const encoder = JsonEncoder.withIndent('  ');
      currentJsonText = encoder.convert(currentDraft!.profile);
      jsonValidationError = null;
      isDirty = false;
      await refreshEvidence();
      await fetchAndSyncCloudDraft();
    }
    notifyListeners();
  }

  @override
  Future<void> fetchAndSyncCloudDraft() async {
    if (selectedDefinitionId == null || currentDraft == null) return;
    try {
      final release = await apiClient.fetchRelease(
        selectedDefinitionId!,
        currentDraft!.releaseVersion,
      );
      cloudDraftVersion = currentDraft!.releaseVersion;
      cloudReleaseLifecycleState = release.lifecycleState.toLowerCase();
      cloudDraftExists = cloudReleaseLifecycleState == 'draft';
      if (release.profile != null) {
        cloudDraftPayload = Map<String, dynamic>.from(release.profile!);
        if (cloudDraftExists == true) {
          cloudDigest = release.payloadDigest ??
              release['profileDigest'] as String? ??
              sha256
                  .convert(utf8.encode(canonicalJson(cloudDraftPayload!)))
                  .toString();
          baseCloudDigest ??= cloudDigest;
          updateSyncState();
        }
      }
    } on ProfileAdminNotFoundException {
      cloudDraftVersion = currentDraft!.releaseVersion;
      cloudDraftExists = false;
      cloudReleaseLifecycleState = null;
      cloudDigest = null;
      baseCloudDigest = null;
      cloudDraftPayload = null;
    } catch (_) {
      updateSyncState();
    }
  }

  void updateSyncState() {
    if (cloudDigest != null &&
        baseCloudDigest != null &&
        cloudDigest != baseCloudDigest) {
      if (isDirty) {
        syncState = DraftSyncState.conflict;
      } else {
        syncState = DraftSyncState.cloudChanged;
      }
    } else {
      if (isDirty) {
        syncState = DraftSyncState.modifiedLocally;
      } else {
        syncState = DraftSyncState.saved;
      }
    }
  }

  @override
  Future<void> refreshEvidence() async {
    if (testedDraftDigest != null && !testResultMatchesDraft) {
      resetDraftTestState();
    }
    if (currentDraft == null || selectedDefinitionId == null) {
      currentEvidence = [];
    } else {
      final storedEvidence = await store.loadEvidence(
        profileDefinitionId: selectedDefinitionId!,
        payloadDigest: currentDraft!.payloadDigest,
      );
      currentEvidence = storedEvidence.where((evidence) {
        return ToolProfileAcceptanceEvidence.hasCloudContractShape(
              evidence,
              profile: currentDraft!.profile,
            ) &&
            evidence['profileDefinitionId'] ==
                currentDraft!.profileDefinitionId &&
            evidence['releaseVersion'] == currentDraft!.releaseVersion &&
            evidence['profileDigest'] == currentDraft!.payloadDigest;
      }).toList();
    }
    notifyListeners();
  }

  void updateJsonText(String text) {
    currentJsonText = text;
    isDirty = true;
    updateSyncState();
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, Object?>) {
        jsonValidationError = 'Top-level JSON must be an object.';
      } else {
        EngineProfile.parse(utf8.encode(canonicalJson(decoded)));
        jsonValidationError = null;
      }
    } on FormatException catch (e) {
      jsonValidationError = e.message;
    } catch (e) {
      jsonValidationError = e.toString();
    }
    notifyListeners();
  }

  /// Reverts modified text back to the last saved draft payload on disk.
  Future<void> revertCurrentDraft() async {
    if (selectedDefinitionId == null) return;
    pendingAiProvenance = null;
    await selectDraft(selectedDefinitionId!);
  }

  /// Formats the current JSON text with standard 2-space indentation.
  void formatCurrentJson() {
    try {
      final decoded = jsonDecode(currentJsonText);
      const encoder = JsonEncoder.withIndent('  ');
      currentJsonText = encoder.convert(decoded);
      updateJsonText(currentJsonText);
    } catch (_) {
      // Ignore formatting errors if invalid JSON
    }
  }

  /// Duplicates the current draft as the next release version draft (e.g. v1 -> v2).
  Future<void> duplicateCurrentDraftAsNextRelease() async {
    if (selectedDefinitionId == null || currentDraft == null) return;
    try {
      final decoded =
          Map<String, Object?>.from(jsonDecode(currentJsonText) as Map);
      final currentVer = (decoded['releaseVersion'] as int?) ?? 1;
      final nextVer = currentVer + 1;
      decoded['releaseVersion'] = nextVer;
      const encoder = JsonEncoder.withIndent('  ');
      currentJsonText = encoder.convert(decoded);
      await saveCurrentDraft(
          notes: 'Duplicated from v$currentVer as v$nextVer');
    } catch (e) {
      jsonValidationError = 'Failed to duplicate draft: $e';
      notifyListeners();
    }
  }

  /// Creates next draft version automatically from a published release payload.
  Future<void> createDraftFromRelease({
    required String profileDefinitionId,
    required Map<String, dynamic> releasePayload,
  }) async {
    final releaseVer = (releasePayload['releaseVersion'] as int?) ?? 1;
    final nextVer = releaseVer + 1;
    final newDraftJson = Map<String, Object?>.from(releasePayload);
    newDraftJson['releaseVersion'] = nextVer;

    currentDraft = await store.saveDraft(
      profileDefinitionId: profileDefinitionId,
      profileJson: newDraftJson,
      author: currentSession?.displayName ?? 'developer',
      notes: 'Created draft v$nextVer from published release v$releaseVer',
    );
    await refreshDrafts();
    await selectDraft(profileDefinitionId);
    setWorkerSubView(WorkerSubView.draftAndTest);
    setArea(LabArea.workers);
  }

  Future<void> saveCurrentDraft(
          {String author = 'developer', String notes = ''}) =>
      _refresh('save-local-draft',
          () => _saveCurrentDraft(author: author, notes: notes));

  Future<void> _saveCurrentDraft(
      {String author = 'developer', String notes = ''}) async {
    if (selectedDefinitionId == null || jsonValidationError != null) return;
    final decoded = jsonDecode(currentJsonText) as Map<String, Object?>;
    currentDraft = await store.saveDraft(
      profileDefinitionId: selectedDefinitionId!,
      profileJson: decoded,
      author: author,
      notes: notes,
      provenance: pendingAiProvenance,
    );
    currentMetadata = await store.loadDraftMetadata(selectedDefinitionId!);
    pendingAiProvenance = null;
    isDirty = false;
    updateSyncState();
    await refreshEvidence();
    notifyListeners();
  }

  Future<void> applyRecommendedProviderCompatibilityRange({
    required String min,
    required String maxExclusive,
  }) async {
    if (selectedDefinitionId == null || currentDraft == null) return;
    try {
      final decoded =
          Map<String, Object?>.from(jsonDecode(currentJsonText) as Map);
      final tool = Map<String, Object?>.from(decoded['providerTool'] as Map);
      final ranges = tool['supportedVersions'];
      final parsed = EngineProfile.parse(utf8.encode(canonicalJson(decoded)));
      if (ranges is List &&
          ranges.isNotEmpty &&
          !ToolProfileCompatibility.hasPlaceholderProviderRange(parsed)) {
        return;
      }
      tool['supportedVersions'] = [
        {'min': min, 'maxExclusive': maxExclusive},
      ];
      decoded['providerTool'] = tool;
      updateJsonText(const JsonEncoder.withIndent('  ').convert(decoded));
      await saveCurrentDraft(
        notes: 'Set provider compatibility from tested version $min',
      );
    } on Object catch (error) {
      jsonValidationError = 'Could not apply provider compatibility: $error';
      notifyListeners();
    }
  }

  Future<void> saveCurrentDraftToCloud(
          {bool force = false,
          String author = 'developer',
          String notes = ''}) =>
      _refresh(
          'save-draft',
          () => _saveCurrentDraftToCloud(
              force: force, author: author, notes: notes));

  Future<void> _saveCurrentDraftToCloud({
    bool force = false,
    String author = 'developer',
    String notes = '',
  }) async {
    if (selectedDefinitionId == null || jsonValidationError != null) return;
    final decoded = jsonDecode(currentJsonText) as Map<String, Object?>;

    currentDraft = await store.saveDraft(
      profileDefinitionId: selectedDefinitionId!,
      profileJson: decoded,
      author: author,
      notes: notes,
      provenance: pendingAiProvenance,
    );
    currentMetadata = await store.loadDraftMetadata(selectedDefinitionId!);
    pendingAiProvenance = null;
    await refreshEvidence();

    try {
      if (cloudDraftVersion != currentDraft!.releaseVersion ||
          cloudDraftExists == null) {
        await fetchAndSyncCloudDraft();
      }
      if (cloudDraftExists == null) {
        throw StateError(
          'Could not determine whether this release draft exists on Cloud. Check the Cloud connection and try again.',
        );
      }
      if (!cloudDraftExists! && cloudReleaseLifecycleState != null) {
        throw StateError(
          'Cloud release v${currentDraft!.releaseVersion} is ${cloudReleaseLifecycleState!} and cannot be edited as a draft.',
        );
      }
      final resp = cloudDraftExists == true
          ? await apiClient.updateDraft(
              profileDefinitionId: selectedDefinitionId!,
              releaseVersion: currentDraft!.releaseVersion,
              profile: Map<String, dynamic>.from(decoded),
              expectedBaseDigest: force ? null : baseCloudDigest,
            )
          : await apiClient.createDraftRelease(
              profileDefinitionId: selectedDefinitionId!,
              releaseVersion: currentDraft!.releaseVersion,
              profile: Map<String, dynamic>.from(decoded),
            );
      final newDigest = (resp['payloadDigest'] as String?) ??
          (resp['digest'] as String?) ??
          currentDraft!.payloadDigest;
      baseCloudDigest = newDigest;
      cloudDigest = newDigest;
      cloudDraftPayload = Map<String, dynamic>.from(decoded);
      cloudDraftExists = true;
      cloudDraftVersion = currentDraft!.releaseVersion;
      cloudReleaseLifecycleState = 'draft';
      isDirty = false;
      syncState = DraftSyncState.saved;
      cloudError = null;
    } on StateError catch (e) {
      if (e.message.contains('409') ||
          e.message.toLowerCase().contains('conflict') ||
          e.message.contains('digest mismatch')) {
        syncState = DraftSyncState.conflict;
        cloudError = 'Draft conflict detected on Cloud: ${e.message}';
      } else {
        cloudError = 'Save to Cloud failed: ${e.message}';
      }
      rethrow;
    } catch (e) {
      cloudError = 'Save to Cloud failed: $e';
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> resolveConflictKeepLocal() async {
    await saveCurrentDraftToCloud(
      force: true,
      notes: 'Resolved conflict by forcing local draft payload onto Cloud',
    );
  }

  Future<void> resolveConflictKeepCloud() async {
    if (cloudDraftPayload == null || selectedDefinitionId == null) return;
    const encoder = JsonEncoder.withIndent('  ');
    currentJsonText = encoder.convert(cloudDraftPayload!);
    currentDraft = await store.saveDraft(
      profileDefinitionId: selectedDefinitionId!,
      profileJson: cloudDraftPayload!,
      notes: 'Resolved conflict by accepting Cloud draft payload',
    );
    baseCloudDigest = cloudDigest;
    isDirty = false;
    jsonValidationError = null;
    syncState = DraftSyncState.saved;
    notifyListeners();
  }

  /// Creates an unsigned local candidate from the selected Cloud definition.
  Future<void> createInitialDraft() => _refresh('initial-draft', () async {
        final worker = selectedCloudWorker;
        final definition = selectedCloudDefinition;
        final id = selectedDefinitionId;
        if (worker == null ||
            definition == null ||
            id == null ||
            currentDraft != null ||
            cloudReleases.isNotEmpty) {
          return;
        }
        if (await store.loadDraft(id) != null) {
          await selectDraft(id);
          return;
        }
        final starter = definition['starterTemplate'];
        if (starter != null) {
          if (starter is! Map ||
              starter['schemaVersion'] != 1 ||
              starter['profile'] is! Map) {
            throw StateError('Unsupported starter template');
          }
          final payload = Map<String, Object?>.from(
              jsonDecode(jsonEncode(starter['profile'])) as Map);
          if (payload['profileDefinitionId'] != id ||
              payload['logicalWorkerTypeId'] != worker['workerTypeId'] ||
              payload['releaseVersion'] != 1 ||
              ((payload['providerTool'] as Map?)?['executableCandidates']
                          as List?)
                      ?.contains(definition['providerToolName']) !=
                  true) {
            throw StateError(
                'Starter template does not match the selected Worker');
          }
          await store.saveDraft(
              profileDefinitionId: id,
              profileJson: payload,
              notes: 'Created from Cloud starter template');
          draftDefinitionIds = await store.listDraftDefinitionIds();
          if (selectedDefinitionId == id) {
            await selectDraft(id);
          }
        } else {
          await createNewDraft(
              profileDefinitionId: id,
              workerTypeId: worker['workerTypeId'] as String,
              providerToolName: definition['providerToolName'] as String,
              activate: false);
          draftDefinitionIds = await store.listDraftDefinitionIds();
          if (selectedDefinitionId == id) {
            await selectDraft(id);
          }
        }
        if (selectedDefinitionId == id) {
          setWorkerSubView(WorkerSubView.draftAndTest);
        }
      });

  Future<void> createNewDraft({
    required String profileDefinitionId,
    required String workerTypeId,
    required String providerToolName,
    bool activate = true,
  }) async {
    final template = <String, Object?>{
      'schemaVersion': 1,
      'profileDefinitionId': profileDefinitionId,
      'releaseVersion': 1,
      'logicalWorkerTypeId': workerTypeId,
      'engineFamily': 'cli',
      'engineCompatibility': {'min': '1.0.0', 'maxExclusive': '2.0.0'},
      'providerTool': {
        'name': providerToolName,
        'executableCandidates': [providerToolName],
        'discovery': {'standardLocations': [], 'allowPathSearch': true},
        'versionProbe': {
          'arguments': ['--version'],
          'timeoutMs': 10000,
          'source': 'stdout',
          'extract': {'kind': 'regex_capture', 'patternId': 'semver'}
        },
        'supportedVersions': <Map<String, String>>[],
      },
      'environment': {
        'passthrough': ['PATH', 'HOME'],
        'set': {}
      },
      'probe': {
        'passive': {
          'checks': [
            {
              'id': 'auth',
              'arguments': ['--version'],
              'timeoutMs': 5000,
              'successExitCodes': [0],
              'failureIssueCode': 'provider_authentication_required'
            }
          ],
          'configChecks': []
        }
      },
      'execution': {
        'arguments': ['run', '{{prompt}}'],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'plain_text'},
        'events': []
      },
      'session': {
        'supported': false,
        'formatId': 'session-v1',
        'compatibleFormatIds': ['session-v1'],
        'resumeArguments': [],
        'requireObservedIdMatch': false
      },
      'model': {
        'supported': false,
        'arguments': [],
        'unknownModelPolicy': 'pass_through'
      },
      'timeout': {'providerArguments': [], 'providerReserveMs': 0},
      'sandbox': {
        'mappings': {
          'restricted': [],
          'provider_default': [],
          'full_access': []
        }
      },
      'progress': [],
      'errors': {
        'mappings': [
          {
            'evidence': {'kind': 'exit_code', 'value': 2},
            'issueCode': 'provider_failure'
          }
        ]
      },
      'capabilities': ['text'],
      'compatibilityOverrides': []
    };

    await store.saveDraft(
      profileDefinitionId: profileDefinitionId,
      profileJson: template,
      notes: 'Initial template generated by Profile Lab',
    );
    if (activate) {
      await refreshDrafts();
      await selectDraft(profileDefinitionId);
    }
  }

  Future<void> deleteCurrentDraft() async {
    if (selectedDefinitionId == null) return;
    await store.deleteDraft(selectedDefinitionId!);
    await refreshDrafts();
  }

  @override
  Future<void> discoverInstalledProviders() =>
      _refresh('providers', _discoverInstalledProviders);

  Future<void> _discoverInstalledProviders() async {
    const locator = CliExecutableLocator();
    final standardPathsByExecutable = <String, Set<String>>{};

    void addExecutable(Object? value,
        {Iterable<String> standardPaths = const []}) {
      if (value is! String || value.trim().isEmpty) return;
      final executable = value.trim();
      final paths = standardPathsByExecutable.putIfAbsent(
        executable,
        () => <String>{},
      );
      paths.addAll(standardPaths.where((path) => path.trim().isNotEmpty));
    }

    void addProfile(Object? value) {
      if (value is! Map) return;
      final profile = value['profile'] is Map ? value['profile'] as Map : value;
      final providerTool = profile['providerTool'];
      if (providerTool is! Map) return;

      final discovery = providerTool['discovery'];
      final standardPaths =
          discovery is Map && discovery['standardLocations'] is List
              ? (discovery['standardLocations'] as List)
                  .whereType<String>()
                  .toList(growable: false)
              : const <String>[];
      addExecutable(providerTool['name'], standardPaths: standardPaths);
      final candidates = providerTool['executableCandidates'];
      if (candidates is List) {
        for (final candidate in candidates.whereType<String>()) {
          addExecutable(candidate, standardPaths: standardPaths);
        }
      }
    }

    // Worker catalog identities and Profile-declared candidates are the only
    // sources for local executable discovery. There is no built-in provider
    // inventory, so newly registered Workers are discoverable without a code
    // change.
    for (final worker in cloudWorkers) {
      addExecutable(worker['providerToolName']);
    }
    addProfile(selectedCloudDefinition);
    addProfile(selectedCloudRelease);
    for (final release in cloudReleases) {
      addProfile(release);
    }
    for (final definitionId in await store.listDraftDefinitionIds()) {
      try {
        addProfile((await store.loadDraft(definitionId))?.profile);
      } on Object {
        // One malformed local draft must not hide other configured tools.
      }
    }
    addProfile(currentDraft?.profile);
    try {
      final decoded = jsonDecode(currentJsonText);
      addProfile(decoded);
    } on FormatException {
      // An invalid editor buffer does not replace the last valid draft data.
    }

    configuredProviderExecutables = standardPathsByExecutable.keys.toList()
      ..sort();
    detectedProviderPaths.clear();
    for (final executable in configuredProviderExecutables) {
      final path = await locator.locate(
        executable,
        standardPaths: standardPathsByExecutable[executable]!,
        environment: {...Platform.environment, ...sandboxEnvironmentOverrides},
      );
      if (path != null) {
        detectedProviderPaths[executable] = path;
      }
    }
    notifyListeners();
  }
}
