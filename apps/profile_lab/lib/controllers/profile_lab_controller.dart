import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:flutter/foundation.dart';

import '../bundled_cli_worker_engine_loader.dart';
import '../profile_admin_api_client.dart';
import '../profile_lab_auth.dart';
import '../profile_lab_cloud_config.dart';
import '../profile_lab_paths.dart';
import '../profile_lab_session_store.dart';
import '../profile_lab_test_sandbox.dart';
import '../utils/profile_payload_migrations.dart';
import '../utils/profile_activity_mapping_fixtures.dart';

import '../models/selected_worker_state.dart';

export '../models/selected_worker_state.dart';

part 'profile_lab_controller_drafts.dart';
part 'profile_lab_controller_testing.dart';
part 'profile_lab_controller_session.dart';
part 'profile_lab_controller_cloud.dart';

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
        _cloudSettingsStore = ProfileLabCloudSettingsStore(
          paths.cloudSettingsFile,
        );

  final ProfileLabPaths paths;
  final DraftProfileStore store;
  final PlatformProcessSupervisor _processSupervisor;

  /// Isolates provider discovery/probes in controlled acceptance environments.
  @visibleForTesting
  final Map<String, String> sandboxEnvironmentOverrides;
  final ProfileLabSessionStore _sessionStore;
  final ProfileLabCloudSettingsStore _cloudSettingsStore;
  ProfileAdminApiClient? _apiClientOverride;

  List<String> draftDefinitionIds = [];
  String? selectedDefinitionId;
  LocalDraftProfileCandidate? currentDraft;
  DraftProfileMetadata? currentMetadata;
  String currentJsonText = '';
  String? jsonValidationError;
  String? jsonValidationLocation;
  bool isDirty = false;
  Timer? _recoveryTimer;

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
  String? testedActivityMappingDigest;
  ProfileActivityMappingReplayResult? lastActivityMappingReplay;

  /// These fields bind local eligibility to the one current Worker Profile.
  Map<String, dynamic>? currentCloudProfileSnapshot;
  int currentProfileRevision = 0;
  String? currentProfileDigest;
  String? candidateCloudValidatedDigest;

  bool get testResultMatchesDraft =>
      currentDraft != null &&
      testedDraftDigest == currentDraft!.payloadDigest &&
      testedProfileDefinitionId == currentDraft!.profileDefinitionId;

  bool get activityMappingTestMatchesDraft =>
      currentDraft != null &&
      testedActivityMappingDigest == currentDraft!.payloadDigest &&
      lastActivityMappingReplay != null;

  void resetDraftTestState() {
    testStartedAt = null;
    testCompletedAt = null;
    testedDraftDigest = null;
    testedProfileDefinitionId = null;
    testedActivityMappingDigest = null;
    lastActivityMappingReplay = null;
    candidateCloudValidatedDigest = null;
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

  // Cloud dynamic catalog and current Profile state.
  List<Map<String, dynamic>> cloudWorkers = [];
  Map<String, dynamic>? selectedCloudWorker;
  Map<String, dynamic>? selectedCloudDefinition;
  bool isSubmittingCloudEvidence = false;
  String? profileFilePath;
  String? profileFileError;
  bool profileFileUpdateAvailable = false;
  final Map<String, Future<void>> _refreshes = {};
  final Set<String> _loaded = {};
  int _cloudGeneration = 0;
  bool get isPublishing => _refreshes.containsKey('publish');
  bool get isValidatingCandidate =>
      _refreshes.containsKey('validate-candidate');
  bool get isSavingLocally => _refreshes.containsKey('save-local-draft');
  bool get isScanningProviders => _refreshes.containsKey('providers');
  String? definitionsError;
  String? draftError;
  String? startupError;
  bool get isLoadingWorkerCatalog => _refreshes.containsKey('catalog');
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
            (key != 'catalog' || workerCatalogError == null)) {
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
    _recoveryTimer?.cancel();
    _disposed = true;
    super.dispose();
  }

  ProfileLabAccessReadModel? labAccess;
  String? labAccessError;
  bool get isCheckingLabAccess => _refreshes.containsKey('access');
  bool get canPublish => labAccess?.profilesAdmin == true;

  bool get candidateIsCloudValidated =>
      currentDraft != null &&
      candidateCloudValidatedDigest == currentDraft!.payloadDigest;

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
  ProfileAdminApiClient get apiClient =>
      _apiClientOverride ??
      ProfileAdminApiClient(baseUrl: cloudUrl, session: currentSession);

  // Authentication state
  ProfileLabSession? currentSession;
  bool isSigningIn = false;
  String? authError;
  String cloudUrl = ProfileLabCloudConfig.buildDefaultOrigin;
  ProfileLabAuthClient? _activeAuthClient;
  ProfileLabAuthIntent? _activeAuthIntent;
  bool _cancelSignInRequested = false;

  /// Unified UX state model for the selected logical Worker and its Profile.
  SelectedWorkerState get selectedWorkerState =>
      SelectedWorkerState.fromController(this as ProfileLabController);

  /// Loads the Worker catalog once an authorized session is available.
  Future<void> ensureWorkerCatalog() async {
    if (currentSession == null ||
        _disposed ||
        labAccess?.profilesAdmin != true ||
        labAccessError != null) {
      return;
    }
    if (!hasLoadedWorkerCatalog) await fetchCloudCatalog();
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
    final configuredOrigin = ProfileLabCloudConfig.isLocalBuild
        ? null
        : await _cloudSettingsStore.loadOverride();
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
    definitionsError = null;
    workerCatalogError = null;
    workerCatalogUnauthorized = false;
    cloudWorkers = [];
    selectedCloudWorker = null;
    selectedCloudDefinition = null;
    currentCloudProfileSnapshot = null;
    currentProfileRevision = 0;
    currentProfileDigest = null;
    candidateCloudValidatedDigest = null;
  }

  // Cross-feature operations used by the composition root during initialization
  // and selection. Feature implementations live in the controller parts below.
  Future<void> refreshDrafts();
  Future<void> loadProfileFromFolder({bool force = false});
  Future<void> selectDraft(String profileDefinitionId);
  Future<void> refreshEvidence();
  Future<void> discoverInstalledProviders();
  Future<void> loadSavedSession();
  Future<void> fetchCloudCatalog();
}

class ProfileLabController extends _ProfileLabControllerState
    with
        _ProfileLabDraftOperations,
        _ProfileLabTestOperations,
        _ProfileLabSessionOperations,
        _ProfileLabCloudOperations {
  ProfileLabController({
    required super.paths,
    super.processSupervisor,
    super.apiClientOverride,
    super.sessionStore,
    super.sandboxEnvironmentOverrides,
  });
}
