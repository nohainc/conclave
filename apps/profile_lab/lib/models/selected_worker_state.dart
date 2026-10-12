import '../controllers/profile_lab_controller.dart';

/// Compact operational state for the selected logical Worker.
enum WorkerLifecycleStatus {
  noSelection,
  noProfile,
  candidateModified,
  testRequired,
  testsPassed,
  publicationUnavailable,
  current;

  String get label => switch (this) {
        WorkerLifecycleStatus.noSelection => 'No Worker Selected',
        WorkerLifecycleStatus.noProfile => 'No Profile',
        WorkerLifecycleStatus.candidateModified => 'Candidate Modified',
        WorkerLifecycleStatus.testRequired => 'Test Required',
        WorkerLifecycleStatus.testsPassed => 'Tests Passed',
        WorkerLifecycleStatus.publicationUnavailable =>
          'Publication Unavailable',
        WorkerLifecycleStatus.current => 'Current Profile',
      };
}

class SelectedWorkerState {
  const SelectedWorkerState({
    required this.workerTypeId,
    required this.displayName,
    required this.description,
    required this.providerToolName,
    required this.lifecycleState,
    required this.visibilityState,
    required this.sortOrder,
    required this.profileDefinitionId,
    required this.definitionDisplayName,
    required this.definitionStatus,
    required this.hasLocalCandidate,
    required this.localCandidateVersion,
    required this.localCandidateDigest,
    required this.isCandidateDirty,
    required this.providerDetectedPath,
    required this.isProviderDetected,
    required this.isTesting,
    required this.lastTestResult,
    required this.testStatusMessage,
    required this.canPublish,
    required this.publicationBlockReason,
    required this.currentRevision,
    required this.currentDigest,
    required this.status,
  });

  final String workerTypeId;
  final String displayName;
  final String description;
  final String providerToolName;
  final String lifecycleState;
  final String visibilityState;
  final int sortOrder;
  final String? profileDefinitionId;
  final String? definitionDisplayName;
  final String? definitionStatus;
  final bool hasLocalCandidate;
  final int? localCandidateVersion;
  final String? localCandidateDigest;
  final bool isCandidateDirty;
  final String? providerDetectedPath;
  final bool isProviderDetected;
  final bool isTesting;
  final String? lastTestResult;
  final String? testStatusMessage;
  final bool canPublish;
  final String? publicationBlockReason;
  final int currentRevision;
  final String? currentDigest;
  final WorkerLifecycleStatus status;

  String get conciseProfileStatus {
    if (isCandidateDirty) return 'Candidate unsaved';
    if (currentRevision > 0) return 'Current r$currentRevision';
    if (hasLocalCandidate) return 'Candidate saved';
    return 'No Profile';
  }

  factory SelectedWorkerState.fromController(ProfileLabController controller) {
    final worker = controller.selectedCloudWorker;
    if (worker == null) return SelectedWorkerState._empty();
    final workerTypeId = worker['workerTypeId'] as String? ?? '';
    final displayName = worker['displayName'] as String? ?? workerTypeId;
    final description =
        worker['description'] as String? ?? 'No description provided.';
    final lifecycleState = worker['lifecycleState'] as String? ?? 'active';
    final visibilityState = worker['visibilityState'] as String? ?? 'visible';
    final sortOrder = (worker['sortOrder'] as num?)?.toInt() ?? 100;
    final definition = controller.selectedCloudDefinition;
    final profileDefId = controller.selectedDefinitionId ??
        (worker['profileDefinitionId'] as String?);
    final candidate = controller.currentDraft;
    final hasCandidate = candidate != null;
    final lastTestResult =
        controller.testResultMatchesDraft ? controller.lastTestResult : null;
    final canPublish = controller.canPublish;
    String? blockReason;
    if (!canPublish) {
      if (controller.labAccess?.profilesAdmin != true) {
        blockReason = 'Profile Lab authorization is required to publish.';
      } else if (controller.labAccess?.signerReady != true) {
        blockReason = 'Cloud Profile signing is not ready.';
      } else {
        blockReason = 'Publication is not available for this session.';
      }
    }
    final currentRevision = controller.currentProfileRevision;
    final currentDigest = controller.currentProfileDigest;
    final providerTool = worker['providerToolName'] as String? ??
        (candidate?.profile['providerTool'] as Map?)?['name']?.toString() ??
        '';
    final detectedPath = providerTool.isEmpty
        ? null
        : controller.detectedProviderPaths[providerTool];
    final status = !hasCandidate && currentRevision == 0
        ? WorkerLifecycleStatus.noProfile
        : controller.isDirty
            ? WorkerLifecycleStatus.candidateModified
            : hasCandidate && lastTestResult != 'pass'
                ? WorkerLifecycleStatus.testRequired
                : hasCandidate && lastTestResult == 'pass' && !canPublish
                    ? WorkerLifecycleStatus.publicationUnavailable
                    : hasCandidate && lastTestResult == 'pass'
                        ? WorkerLifecycleStatus.testsPassed
                        : currentRevision > 0
                            ? WorkerLifecycleStatus.current
                            : WorkerLifecycleStatus.noProfile;
    return SelectedWorkerState(
      workerTypeId: workerTypeId,
      displayName: displayName,
      description: description,
      providerToolName: providerTool,
      lifecycleState: lifecycleState,
      visibilityState: visibilityState,
      sortOrder: sortOrder,
      profileDefinitionId: profileDefId,
      definitionDisplayName: definition?['displayName'] as String?,
      definitionStatus: definition?['status'] as String?,
      hasLocalCandidate: hasCandidate,
      localCandidateVersion: candidate?.releaseVersion,
      localCandidateDigest: candidate?.payloadDigest,
      isCandidateDirty: controller.isDirty,
      providerDetectedPath: detectedPath,
      isProviderDetected: detectedPath != null,
      isTesting: controller.isTesting,
      lastTestResult: lastTestResult,
      testStatusMessage: controller.testStatusMessage,
      canPublish: canPublish,
      publicationBlockReason: blockReason,
      currentRevision: currentRevision,
      currentDigest: currentDigest,
      status: status,
    );
  }

  factory SelectedWorkerState._empty() => const SelectedWorkerState(
        workerTypeId: '',
        displayName: '',
        description: '',
        providerToolName: '',
        lifecycleState: 'inactive',
        visibilityState: 'hidden',
        sortOrder: 100,
        profileDefinitionId: null,
        definitionDisplayName: null,
        definitionStatus: null,
        hasLocalCandidate: false,
        localCandidateVersion: null,
        localCandidateDigest: null,
        isCandidateDirty: false,
        providerDetectedPath: null,
        isProviderDetected: false,
        isTesting: false,
        lastTestResult: null,
        testStatusMessage: null,
        canPublish: false,
        publicationBlockReason: null,
        currentRevision: 0,
        currentDigest: null,
        status: WorkerLifecycleStatus.noSelection,
      );
}
