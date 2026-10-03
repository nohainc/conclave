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

part 'profile_lab_controller_drafts.dart';
part 'profile_lab_controller_testing.dart';
part 'profile_lab_controller_session.dart';
part 'profile_lab_controller_cloud.dart';
part 'profile_lab_controller_ai.dart';

enum LabTab {
  workers,
  profiles,
  tests,
  releases,
  workspaces,
  audit;

  static const LabTab drafts = LabTab.profiles;
  static const LabTab testBench = LabTab.profiles;
  static const LabTab evidence = LabTab.tests;
  static const LabTab diagnostics = LabTab.profiles;
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
  final ProfileLabSessionStore _sessionStore;
  final ProfileLabCloudSettingsStore _cloudSettingsStore;
  ProfileAdminApiClient? _apiClientOverride;

  LabTab selectedTab = LabTab.workers;
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
  bool isLoadingCloud = false;
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

  void setTab(LabTab tab) {
    selectedTab = tab;
    if (tab == LabTab.workspaces &&
        workspaceChannels.isEmpty &&
        currentSession != null) {
      fetchWorkspaceChannels();
    }
    notifyListeners();
  }

  Future<void> fetchWorkspaceChannels() async {
    isLoadingWorkspaces = true;
    workspaceError = null;
    notifyListeners();
    try {
      workspaceChannels = (await apiClient.listWorkspaceChannels())
          .map((workspace) => workspace.toJson())
          .toList();
    } catch (e) {
      workspaceError = e.toString();
    } finally {
      isLoadingWorkspaces = false;
      notifyListeners();
    }
  }

  Future<void> updateWorkspaceChannel(
      String workspaceId, String channel) async {
    isLoadingWorkspaces = true;
    workspaceError = null;
    notifyListeners();
    try {
      await apiClient.setWorkspaceChannel(
        workspaceId: workspaceId,
        channel: channel,
      );
      await fetchWorkspaceChannels();
    } catch (e) {
      workspaceError = e.toString();
      isLoadingWorkspaces = false;
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
  });

  void applyAiDraftProposal({
    required Map<String, dynamic> profile,
    required Map<String, Object?> provenance,
  }) {
    pendingAiProvenance = Map<String, Object?>.from(provenance);
    updateJsonText(const JsonEncoder.withIndent('  ').convert(profile));
  }
}
