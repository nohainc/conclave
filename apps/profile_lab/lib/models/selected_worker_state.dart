import '../controllers/profile_lab_controller.dart';

/// State of the one current Worker Profile and its local candidate.
enum WorkerLifecycleStatus {
  noSelection,
  noProfile,
  draftCreated,
  draftModified,
  draftSynced,
  testRequired,
  testsPassed,
  publicationUnavailable,
  current;

  String get label => switch (this) {
        WorkerLifecycleStatus.noSelection => 'No Worker Selected',
        WorkerLifecycleStatus.noProfile => 'No Profile',
        WorkerLifecycleStatus.draftCreated => 'Draft Created',
        WorkerLifecycleStatus.draftModified => 'Draft Modified',
        WorkerLifecycleStatus.draftSynced => 'Draft Synced',
        WorkerLifecycleStatus.testRequired => 'Test Required',
        WorkerLifecycleStatus.testsPassed => 'Tests Passed',
        WorkerLifecycleStatus.publicationUnavailable =>
          'Publication Unavailable',
        WorkerLifecycleStatus.current => 'Current Profile',
      };
}

class WorkerNextAction {
  const WorkerNextAction(
      {required this.title,
      required this.description,
      required this.actionLabel,
      required this.subView});
  final String title;
  final String description;
  final String actionLabel;
  final WorkerSubView subView;
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
    required this.hasLocalDraft,
    required this.localDraftVersion,
    required this.localDraftDigest,
    required this.isDraftDirty,
    required this.syncState,
    required this.cloudDraftExists,
    required this.cloudDraftVersion,
    required this.cloudDraftDigest,
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
    required this.nextAction,
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
  final bool hasLocalDraft;
  final int? localDraftVersion;
  final String? localDraftDigest;
  final bool isDraftDirty;
  final DraftSyncState syncState;
  final bool cloudDraftExists;
  final int? cloudDraftVersion;
  final String? cloudDraftDigest;
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
  final WorkerNextAction nextAction;

  String get conciseProfileStatus {
    if (isDraftDirty) return 'Draft modified';
    if (currentRevision > 0) return 'Current r$currentRevision';
    if (hasLocalDraft) return 'Draft';
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
    final draft = controller.currentDraft;
    final hasLocalDraft = draft != null;
    final lastTestResult = controller.testResultMatchesDraft
        ? controller.lastTestResult
        : controller.lastTestResult;
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
        (draft?.profile['providerTool'] as Map?)?['name']?.toString() ??
        '';
    final detectedPath = providerTool.isEmpty
        ? null
        : controller.detectedProviderPaths[providerTool];
    final status = !hasLocalDraft && currentRevision == 0
        ? WorkerLifecycleStatus.noProfile
        : controller.isDirty
            ? WorkerLifecycleStatus.draftModified
            : hasLocalDraft && lastTestResult != 'pass'
                ? WorkerLifecycleStatus.testRequired
                : hasLocalDraft && lastTestResult == 'pass' && !canPublish
                    ? WorkerLifecycleStatus.publicationUnavailable
                    : hasLocalDraft && lastTestResult == 'pass'
                        ? WorkerLifecycleStatus.testsPassed
                        : currentRevision > 0
                            ? WorkerLifecycleStatus.current
                            : WorkerLifecycleStatus.draftCreated;
    final WorkerNextAction nextAction = switch (status) {
      WorkerLifecycleStatus.noProfile => const WorkerNextAction(
          title: 'Configure Profile',
          description: 'Create a local candidate for this Worker.',
          actionLabel: 'Configure Profile',
          subView: WorkerSubView.draftAndTest),
      WorkerLifecycleStatus.draftModified => const WorkerNextAction(
          title: 'Save Unsaved Changes',
          description: 'Save the candidate before running the test ladder.',
          actionLabel: 'Review & Save',
          subView: WorkerSubView.draftAndTest),
      WorkerLifecycleStatus.testRequired => const WorkerNextAction(
          title: 'Test the Profile',
          description: 'Run the complete local test ladder for this candidate.',
          actionLabel: 'Run Profile Tests',
          subView: WorkerSubView.draftAndTest),
      WorkerLifecycleStatus.publicationUnavailable => const WorkerNextAction(
          title: 'Publication Unavailable',
          description:
              'Profile Lab authorization or Cloud signing is not ready.',
          actionLabel: 'Inspect Access',
          subView: WorkerSubView.overview),
      WorkerLifecycleStatus.testsPassed => const WorkerNextAction(
          title: 'Publish Profile',
          description:
              'The tested candidate is ready for one atomic publication.',
          actionLabel: 'Publish Profile',
          subView: WorkerSubView.draftAndTest),
      _ => const WorkerNextAction(
          title: 'Test the Profile',
          description:
              'Run the test ladder to verify this Worker configuration.',
          actionLabel: 'Open Draft & Test',
          subView: WorkerSubView.draftAndTest),
    };
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
      hasLocalDraft: hasLocalDraft,
      localDraftVersion: draft?.releaseVersion,
      localDraftDigest: draft?.payloadDigest,
      isDraftDirty: controller.isDirty,
      syncState: controller.syncState,
      cloudDraftExists: controller.cloudDraftExists ?? false,
      cloudDraftVersion: controller.cloudDraftVersion,
      cloudDraftDigest: controller.cloudDigest,
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
      nextAction: nextAction,
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
        hasLocalDraft: false,
        localDraftVersion: null,
        localDraftDigest: null,
        isDraftDirty: false,
        syncState: DraftSyncState.saved,
        cloudDraftExists: false,
        cloudDraftVersion: null,
        cloudDraftDigest: null,
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
        nextAction: WorkerNextAction(
            title: 'Select a Worker',
            description: 'Choose a Worker from the catalog.',
            actionLabel: 'Select Worker',
            subView: WorkerSubView.overview),
      );
}
