import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../bundled_cli_worker_engine_loader.dart';
import '../profile_admin_api_client.dart';
import '../profile_lab_auth.dart';
import '../profile_lab_cloud_config.dart';
import '../profile_lab_paths.dart';
import '../profile_lab_session_store.dart';
import '../profile_lab_test_sandbox.dart';
import '../profile_lab_release_trust.dart';
import '../utils/profile_lab_model_proposals.dart';

import '../models/selected_worker_state.dart';

export '../models/selected_worker_state.dart';

part 'profile_lab_controller_drafts.dart';
part 'profile_lab_controller_testing.dart';
part 'profile_lab_controller_session.dart';
part 'profile_lab_controller_cloud.dart';
part 'profile_lab_controller_ai.dart';

enum LabArea {
  workers,
  workspaces,
  audit;
}

enum WorkerSubView {
  overview,
  draftAndTest,
  releases;

  String get label => switch (this) {
        WorkerSubView.overview => 'Overview',
        WorkerSubView.draftAndTest => 'Draft & Test',
        WorkerSubView.releases => 'Releases',
      };
}

enum DraftSyncState {
  saved,
  modifiedLocally,
  cloudChanged,
  conflict;

  String get label => switch (this) {
        DraftSyncState.saved => 'Saved',
        DraftSyncState.modifiedLocally => 'Modified locally',
        DraftSyncState.cloudChanged => 'Cloud changed',
        DraftSyncState.conflict => 'Conflict',
      };
}

class TestExecutionLog {
  const TestExecutionLog({
    required this.timestamp,
    required this.level,
    required this.message,
    this.rawJson,
  });

  final DateTime timestamp;
  final String level;
  final String message;
  final Map<String, Object?>? rawJson;
}

abstract class _ProfileLabControllerState extends ChangeNotifier {
  _ProfileLabControllerState({
    required this.paths,
    PlatformProcessSupervisor? processSupervisor,
    ProfileAdminApiClient? apiClientOverride,
    ProfileLabSessionStore? sessionStore,
    this.sandboxEnvironmentOverrides = const {},
  })  : store = DraftProfileStore(draftsRoot: paths.draftsDirectory),
        _processSupervisor =
            processSupervisor ?? const StandardProcessSupervisor(),
        _apiClientOverride = apiClientOverride,
        _sessionStore = sessionStore ?? ProfileLabSessionStore(paths),
        _cloudSettingsStore =
            ProfileLabCloudSettingsStore(paths.cloudSettingsFile);

  final ProfileLabPaths paths;
  final DraftProfileStore store;
  final PlatformProcessSupervisor _processSupervisor;

  /// Isolates provider discovery/probes in controlled acceptance environments.
  @visibleForTesting
  final Map<String, String> sandboxEnvironmentOverrides;
  final ProfileLabSessionStore _sessionStore;
  final ProfileLabCloudSettingsStore _cloudSettingsStore;
  ProfileAdminApiClient? _apiClientOverride;

  LabArea selectedArea = LabArea.workers;
  List<String> draftDefinitionIds = [];
  String? selectedDefinitionId;
  LocalDraftProfileCandidate? currentDraft;
  DraftProfileMetadata? currentMetadata;
  String currentJsonText = '';
  String? jsonValidationError;
  bool isDirty = false;

  // Draft Sync state & optimistic concurrency
  DraftSyncState syncState = DraftSyncState.saved;
  String? baseCloudDigest;
  String? cloudDigest;
  Map<String, dynamic>? cloudDraftPayload;
  bool? cloudDraftExists;
  int? cloudDraftVersion;
  String? cloudReleaseLifecycleState;

  // Test bench state
  bool isTesting = false;
  String? testStatusMessage;
  String? lastTestResult;
  List<TestExecutionLog> testLogs = [];
  ProfileLabLadderResult? lastLadderResult;
  DateTime? testStartedAt;
  DateTime? testCompletedAt;
  String? testedDraftDigest;
  String? testedProfileDefinitionId;

  bool get testResultMatchesDraft =>
      currentDraft != null &&
      testedDraftDigest == currentDraft!.payloadDigest &&
      testedProfileDefinitionId == currentDraft!.profileDefinitionId;

  void resetDraftTestState() {
    testStartedAt = null;
    testCompletedAt = null;
    testedDraftDigest = null;
    testedProfileDefinitionId = null;
    lastTestResult = null;
    lastLadderResult = null;
    testStatusMessage = null;
    activeLadderStages = [];
    testLogs = [];
  }

  List<ProfileLabLadderStageResult> activeLadderStages = [];
  List<String> configuredProviderExecutables = [];
  Map<String, String> detectedProviderPaths = {};
  File? engineExecutable;
  ProfileLabTestSandbox? _activeTestSandbox;

  // Local evidence state
  List<Map<String, Object?>> currentEvidence = [];

  // Cloud dynamic catalog & release state
  List<Map<String, dynamic>> cloudWorkers = [];
  Map<String, dynamic>? selectedCloudWorker;
  Map<String, dynamic>? selectedCloudDefinition;
  List<Map<String, dynamic>> cloudReleases = [];
  Map<String, dynamic>? selectedCloudRelease;
  List<Map<String, dynamic>> cloudEvidence = [];
  List<Map<String, dynamic>> cloudAuditEvents = [];
  bool isSubmittingCloudEvidence = false;
  bool isGeneratingAiProposal = false;
  List<ProfileLabAiModelOption> availableAiModels = [];
  String? aiProposalError;
  Map<String, Object?>? pendingAiProvenance;
  ProfileLabTestSandbox? _activeAiSandbox;
  final Map<String, Future<void>> _refreshes = {};
  final Set<String> _loaded = {};
  int _cloudGeneration = 0;
  final Set<String> updatingWorkspaceIds = {};
  bool get isCreatingInitialDraft => _refreshes.containsKey('initial-draft');
  bool get hasStarterTemplate =>
      selectedCloudDefinition?['starterTemplate'] != null;
  bool get canCreateInitialDraft =>
      selectedCloudWorker != null &&
      selectedCloudDefinition != null &&
      currentDraft == null &&
      cloudReleases.isEmpty &&
      definitionsError == null &&
      releasesError == null &&
      !isLoadingDefinitions &&
      !isLoadingReleases &&
      !isCreatingInitialDraft;
  bool get isPublishing => _refreshes.containsKey('publish');
  bool get isSavingLocally => _refreshes.containsKey('save-local-draft');
  bool get isSavingToCloud => _refreshes.containsKey('save-draft');
  bool get isRollingBack => _refreshes.containsKey('rollback');
  bool get isPromoting => _refreshes.containsKey('promote');
  bool get isRevoking => _refreshes.containsKey('revoke');
  bool get isScanningProviders => _refreshes.containsKey('providers');
  String? releasesError;
  String? evidenceError;
  String? auditError;
  String? definitionsError;
  bool get isLoadingWorkerCatalog => _refreshes.containsKey('catalog');
  bool get isLoadingDefinitions =>
      _refreshes.keys.any((k) => k.startsWith('definition:'));
  bool get isLoadingReleases =>
      _refreshes.keys.any((k) => k.startsWith('releases:'));
  bool get isLoadingEvidence =>
      _refreshes.keys.any((k) => k.startsWith('evidence:'));
  bool get isLoadingAudit => _refreshes.keys.any((k) => k.startsWith('audit:'));
  String? workerCatalogError;
  bool workerCatalogUnauthorized = false;
  bool get hasLoadedWorkerCatalog => _loaded.contains('catalog');

  Future<void> _refresh(String key, Future<void> Function() action) {
    final pending = _refreshes[key];
    if (pending != null) return pending;
    final generation = _cloudGeneration;
    final completer = Completer<void>();
    _refreshes[key] = completer.future;
    notifyListeners();
    unawaited(() async {
      try {
        await action();
        if (generation == _cloudGeneration &&
            (key != 'catalog' || workerCatalogError == null) &&
            (key != 'workspaces' || workspaceError == null) &&
            (!key.startsWith('releases:') || releasesError == null)) {
          _loaded.add(key);
        }
        completer.complete();
      } catch (error, stack) {
        completer.completeError(error, stack);
      } finally {
        if (identical(_refreshes[key], completer.future)) {
          _refreshes.remove(key);
        }
        notifyListeners();
      }
    }());
    return completer.future;
  }

  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  ProfileLabAccessReadModel? labAccess;
  String? labAccessError;
  bool get isCheckingLabAccess => _refreshes.containsKey('access');
  bool get canPublish =>
      labAccess?.releaseManager == true &&
      labAccess?.signerReady == true &&
      labAccess?.draftsOnly == false;

  Future<void> refreshLabAccess() => _refresh('access', () async {
        final generation = _cloudGeneration;
        labAccessError = null;
        try {
          final result = await apiClient.fetchLabAccess();
          if (generation != _cloudGeneration) return;
          labAccess = result;
        } catch (e) {
          if (generation != _cloudGeneration) return;
          labAccess = null;
          labAccessError = 'Failed to verify Profile Lab access: $e';
        }
      });

  String? cloudError;
  bool auditFilterCurrentDefinition = false;
  // Controlled Workspace rollout channels state
  List<Map<String, dynamic>> workspaceChannels = [];
  bool isLoadingWorkspaces = false;
  String? workspaceError;

  ProfileAdminApiClient get apiClient =>
      _apiClientOverride ??
      ProfileAdminApiClient(
        baseUrl: cloudUrl,
        session: currentSession,
      );

  // Authentication state
  ProfileLabSession? currentSession;
  bool isSigningIn = false;
  String? authError;
  String cloudUrl = ProfileLabCloudConfig.buildDefaultOrigin;
  ProfileLabAuthClient? _activeAuthClient;
  ProfileLabAuthIntent? _activeAuthIntent;
  bool _cancelSignInRequested = false;

  WorkerSubView workerSubView = WorkerSubView.overview;

  /// Unified UX state model for the selected logical Worker and its Profile.
  SelectedWorkerState get selectedWorkerState =>
      SelectedWorkerState.fromController(this as ProfileLabController);

  void setWorkerSubView(WorkerSubView view) {
    workerSubView = view;
    notifyListeners();
  }

  void setArea(LabArea area) {
    selectedArea = area;
    notifyListeners();
    unawaited(Future<void>.microtask(() => ensureAreaData(area)));
  }

  Future<void> ensureAreaData(LabArea area) async {
    if (currentSession == null ||
        _disposed ||
        labAccess?.profilesAdmin != true ||
        labAccessError != null) {
      return;
    }
    switch (area) {
      case LabArea.workers:
        if (!hasLoadedWorkerCatalog) await fetchCloudCatalog();
      case LabArea.workspaces:
        if (!_loaded.contains('workspaces')) await fetchWorkspaceChannels();
      case LabArea.audit:
        await fetchCloudAudit();
    }
  }

  Future<void> fetchWorkspaceChannels() =>
      _refresh('workspaces', _fetchWorkspaceChannels);

  Future<void> _fetchWorkspaceChannels() async {
    final generation = _cloudGeneration;
    isLoadingWorkspaces = true;
    workspaceError = null;
    notifyListeners();
    try {
      final result = await apiClient.listWorkspaceChannels();
      if (generation != _cloudGeneration) return;
      workspaceChannels =
          result.map((workspace) => workspace.toJson()).toList();
    } catch (e) {
      if (generation == _cloudGeneration) workspaceError = e.toString();
    } finally {
      if (generation == _cloudGeneration) isLoadingWorkspaces = false;
      notifyListeners();
    }
  }

  Future<void> updateWorkspaceChannel(
      String workspaceId, String channel) async {
    if (!updatingWorkspaceIds.add(workspaceId)) return;
    workspaceError = null;
    notifyListeners();
    try {
      await apiClient.setWorkspaceChannel(
          workspaceId: workspaceId, channel: channel);
      await fetchWorkspaceChannels();
    } catch (e) {
      workspaceError = e.toString();
    } finally {
      updatingWorkspaceIds.remove(workspaceId);
      notifyListeners();
    }
  }

  void setApiClientForTesting(ProfileAdminApiClient client) {
    _apiClientOverride = client;
  }

  Future<void> initialize({
    bool loadEngine = true,
    bool scanProviders = true,
  }) async {
    await paths.ensureDirectoriesExist();
    await loadCloudConfiguration();
    await loadSavedSession();
    if (loadEngine) {
      engineExecutable = await loadBundledCliWorkerEngine(
        enginesDirectory: paths.enginesDirectory,
      );
    }
    await refreshDrafts();
    if (scanProviders) {
      await discoverInstalledProviders();
    }
  }

  Future<void> loadCloudConfiguration() async {
    final configuredOrigin = await _cloudSettingsStore.loadOverride();
    cloudUrl = configuredOrigin ?? ProfileLabCloudConfig.buildDefaultOrigin;
    notifyListeners();
  }

  Future<void> setCloudUrl(String value) async {
    final normalized = ProfileLabCloudConfig.normalizeOrigin(value);
    if (normalized != cloudUrl) {
      await _clearCloudOriginState();
    }
    await _cloudSettingsStore.saveOverride(normalized);
    cloudUrl = normalized;
    cloudError = null;
    notifyListeners();
  }

  Future<void> resetCloudUrl() async {
    final defaultOrigin = ProfileLabCloudConfig.buildDefaultOrigin;
    if (defaultOrigin != cloudUrl) {
      await _clearCloudOriginState();
    }
    await _cloudSettingsStore.clearOverride();
    cloudUrl = defaultOrigin;
    cloudError = null;
    notifyListeners();
  }

  Future<void> _clearCloudOriginState() async {
    await _sessionStore.clear();
    currentSession = null;
    _cloudGeneration++;
    _refreshes.clear();
    _loaded.clear();
    labAccess = null;
    labAccessError = null;
    isLoadingWorkspaces = false;
    releasesError = null;
    evidenceError = null;
    auditError = null;
    definitionsError = null;
    workerCatalogError = null;
    workerCatalogUnauthorized = false;
    cloudWorkers = [];
    selectedCloudWorker = null;
    selectedCloudDefinition = null;
    cloudReleases = [];
    selectedCloudRelease = null;
    cloudEvidence = [];
    cloudAuditEvents = [];
    workspaceChannels = [];
    baseCloudDigest = null;
    cloudDigest = null;
    cloudDraftPayload = null;
    syncState = DraftSyncState.saved;
  }

  // Cross-feature operations used by the composition root during initialization
  // and selection. Feature implementations live in the controller parts below.
  Future<void> refreshDrafts();
  Future<void> selectDraft(String profileDefinitionId);
  Future<void> fetchAndSyncCloudDraft();
  Future<void> refreshEvidence();
  Future<void> discoverInstalledProviders();
  Future<void> loadSavedSession();
  Future<void> fetchCloudCatalog();
  Future<void> fetchCloudReleases([String? profileDefinitionId]);
  Future<void> fetchCloudAudit({bool? definitionOnly});
  Future<void> fetchCloudEvidence({String? profileDefinitionId, int? version});
}

class ProfileLabController extends _ProfileLabControllerState
    with
        _ProfileLabDraftOperations,
        _ProfileLabTestOperations,
        _ProfileLabSessionOperations,
        _ProfileLabCloudOperations,
        _ProfileLabAiOperations {
  ProfileLabController({
    required super.paths,
    super.processSupervisor,
    super.apiClientOverride,
    super.sessionStore,
    super.sandboxEnvironmentOverrides,
  });

  void applyAiDraftProposal({
    required Map<String, dynamic> profile,
    required Map<String, Object?> provenance,
  }) {
    pendingAiProvenance = Map<String, Object?>.from(provenance);
    updateJsonText(const JsonEncoder.withIndent('  ').convert(profile));
  }
}
