part of 'profile_lab_controller.dart';

mixin _ProfileLabDraftOperations on _ProfileLabControllerState {
  /// Loads the one bundled source Profile for the selected logical Worker into
  /// a local candidate. Never alters Cloud's published Profile.
  /// The UI must confirm before replacing an existing local candidate.
  Future<void> loadSourceProfileCandidate() async {
    final workerTypeId = selectedCloudWorker?['workerTypeId'] as String?;
    if (workerTypeId == null ||
        !const {'chatgpt', 'gemini', 'claude'}.contains(workerTypeId)) {
      throw StateError('No bundled source Profile for this Worker.');
    }
    final raw = await rootBundle.loadString('assets/profiles/$workerTypeId.json');
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Source Profile must be a JSON object.');
    }
    final source = Map<String, Object?>.from(decoded);
    if (source['logicalWorkerTypeId'] != workerTypeId) {
      throw const FormatException('Source Profile Worker identity mismatch.');
    }
    EngineProfile.parse(utf8.encode(canonicalJson(source)));
    final profileDefinitionId = source['profileDefinitionId'];
    if (profileDefinitionId is! String || profileDefinitionId.isEmpty) {
      throw const FormatException('Source Profile definition ID is missing.');
    }
    await store.saveDraft(
      profileDefinitionId: profileDefinitionId,
      profileJson: source,
      notes: 'Loaded from bundled source Profile',
    );
    selectedDefinitionId = profileDefinitionId;
    draftDefinitionIds = await store.listDraftDefinitionIds();
    resetDraftTestState();
    await selectDraft(profileDefinitionId);
  }

  @override
  Future<void> refreshDrafts() async {
    draftError = null;
    final discoveredDrafts = await store.listDraftDefinitionIds();
    final validDrafts = <String>[];
    for (final profileDefinitionId in discoveredDrafts) {
      try {
        // Validate persisted drafts before selecting one. This also gives the
        // development-only contract cutover a safe way to retire local drafts
        // written with the removed top-level capabilities field.
        await store.loadDraft(profileDefinitionId);
        validDrafts.add(profileDefinitionId);
      } on FormatException catch (error) {
        await store.deleteDraft(profileDefinitionId);
        draftError =
            'Removed obsolete local draft $profileDefinitionId: $error';
      }
    }
    draftDefinitionIds = validDrafts;
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
      jsonValidationLocation = null;
      currentEvidence = [];
    }
    notifyListeners();
  }

  @override
  Future<void> selectDraft(String profileDefinitionId) async {
    selectedDefinitionId = profileDefinitionId;
    pendingAiProvenance = null;
    currentDraft = await store.loadDraft(profileDefinitionId);
    if (currentDraft != null) {
      final migrated = migrateProfilePayload(currentDraft!.profile);
      if (migrated != null) {
        currentDraft = await store.saveDraft(
          profileDefinitionId: profileDefinitionId,
          profileJson: migrated,
          notes: 'Migrated legacy ChatGPT model discovery to Codex app-server.',
        );
      }
    }
    currentMetadata = await store.loadDraftMetadata(profileDefinitionId);
    if (currentDraft != null) {
      const encoder = JsonEncoder.withIndent('  ');
      currentJsonText = encoder.convert(currentDraft!.profile);
      jsonValidationError = null;
      jsonValidationLocation = null;
      isDirty = false;
      await refreshEvidence();
    }
    notifyListeners();
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
        final v9 = evidence['formatVersion'] == 1 &&
            evidence['workerTypeId'] == currentDraft!.logicalWorkerTypeId &&
            evidence['candidateDigest'] == currentDraft!.payloadDigest &&
            evidence['scenarios'] is Map;
        return v9;
      }).toList();
    }
    notifyListeners();
  }

  void updateJsonText(String text) {
    currentJsonText = text;
    isDirty = true;
    jsonValidationLocation = null;
    // A candidate digest changes with the editor buffer. Invalidate both local
    // test evidence and Cloud validation immediately, before the next save.
    resetDraftTestState();
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
      final offset = e.offset;
      if (offset != null && offset >= 0) {
        final safeOffset = offset.clamp(0, text.length);
        final lineStart =
            safeOffset == 0 ? 0 : text.lastIndexOf('\n', safeOffset - 1) + 1;
        final line = '\n'.allMatches(text.substring(0, safeOffset)).length + 1;
        jsonValidationLocation =
            'line $line, column ${safeOffset - lineStart + 1}';
      }
    } catch (e) {
      jsonValidationError = e.toString();
    }
    _scheduleRecoverySnapshot();
    notifyListeners();
  }

  void _scheduleRecoverySnapshot() {
    final profileDefinitionId = selectedDefinitionId;
    if (profileDefinitionId == null) return;
    _recoveryTimer?.cancel();
    final text = currentJsonText;
    _recoveryTimer = Timer(const Duration(milliseconds: 750), () {
      unawaited(() async {
        try {
          await store.saveRecoverySnapshot(
            profileDefinitionId: profileDefinitionId,
            jsonText: text,
          );
        } catch (_) {
          // Recovery is best-effort and must never interrupt editing.
        }
      }());
    });
  }

  /// Restores the newest local recovery buffer into the editor without saving
  /// it as a draft or sending anything to Cloud.
  Future<bool> restoreLatestRecoverySnapshot() async {
    final profileDefinitionId = selectedDefinitionId;
    if (profileDefinitionId == null) return false;
    final text = await store.loadLatestRecoverySnapshot(profileDefinitionId);
    if (text == null) return false;
    updateJsonText(text);
    return true;
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

  Future<void> saveCurrentDraft({
    String author = 'developer',
    String notes = '',
  }) =>
      _refresh(
        'save-local-draft',
        () => _saveCurrentDraft(author: author, notes: notes),
      );

  Future<void> _saveCurrentDraft({
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
    isDirty = false;
    jsonValidationLocation = null;
    await refreshEvidence();
    notifyListeners();
  }

  Future<void> applyRecommendedProviderCompatibilityRange({
    required String min,
    required String maxExclusive,
  }) async {
    if (selectedDefinitionId == null || currentDraft == null) return;
    try {
      final decoded = Map<String, Object?>.from(
        jsonDecode(currentJsonText) as Map,
      );
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

  /// Creates an unsigned local candidate from the selected Cloud definition.
  Future<void> createInitialDraft() => _refresh('initial-draft', () async {
        final worker = selectedCloudWorker;
        final definition = selectedCloudDefinition;
        final id = selectedDefinitionId;
        if (worker == null ||
            definition == null ||
            id == null ||
            currentDraft != null) {
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
            jsonDecode(jsonEncode(starter['profile'])) as Map,
          );
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
          final migrated = migrateProfilePayload(payload);
          await store.saveDraft(
            profileDefinitionId: id,
            profileJson: migrated ?? payload,
            notes: migrated == null
                ? 'Created from Cloud starter template'
                : 'Created from Cloud starter template and migrated legacy ChatGPT model discovery.',
          );
          draftDefinitionIds = await store.listDraftDefinitionIds();
          if (selectedDefinitionId == id) {
            await selectDraft(id);
          }
        } else {
          await createNewDraft(
            profileDefinitionId: id,
            workerTypeId: worker['workerTypeId'] as String,
            providerToolName: definition['providerToolName'] as String,
            activate: false,
          );
          draftDefinitionIds = await store.listDraftDefinitionIds();
          if (selectedDefinitionId == id) {
            await selectDraft(id);
          }
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
          'extract': {'kind': 'regex_capture', 'patternId': 'semver'},
        },
        'supportedVersions': <Map<String, String>>[],
      },
      'environment': {
        'passthrough': ['PATH', 'HOME'],
        'set': {},
      },
      'probe': {
        'passive': {
          'checks': [
            {
              'id': 'auth',
              'arguments': ['--version'],
              'timeoutMs': 5000,
              'successExitCodes': [0],
              'failureIssueCode': 'provider_authentication_required',
            },
          ],
          'configChecks': [],
        },
      },
      'execution': {
        'arguments': ['run', '{{prompt}}'],
        'stdin': {'mode': 'raw_text', 'value': '{{prompt}}'},
        'output': {'mode': 'plain_text'},
        'events': [],
      },
      'session': {
        'supported': false,
        'formatId': 'session-v1',
        'compatibleFormatIds': ['session-v1'],
        'resumeArguments': [],
        'requireObservedIdMatch': false,
      },
      'model': {
        'supported': false,
        'arguments': [],
        'unknownModelPolicy': 'pass_through',
      },
      'timeout': {'providerArguments': [], 'providerReserveMs': 0},
      'sandbox': {
        'mappings': {
          'restricted': [],
          'provider_default': [],
          'full_access': [],
        },
      },
      'progress': [],
      'errors': {
        'mappings': [
          {
            'evidence': {'kind': 'exit_code', 'value': 2},
            'issueCode': 'provider_failure',
          },
        ],
      },
      'compatibilityOverrides': [],
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

    void addExecutable(
      Object? value, {
      Iterable<String> standardPaths = const [],
    }) {
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
      final standardPaths = discovery is Map &&
              discovery['standardLocations'] is List
          ? (discovery['standardLocations'] as List).whereType<String>().toList(
                growable: false,
              )
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
