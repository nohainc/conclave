import '../controllers/profile_lab_controller.dart';
import '../profile_lab_test_sandbox.dart';

/// Computed lifecycle state of the selected logical Worker and its Profile.
enum WorkerLifecycleStatus {
  /// No Worker is selected in Profile Lab.
  noSelection,

  /// Selected Worker has no Profile definition or local draft yet.
  noProfile,

  /// A local draft exists and is saved, but has not been modified or tested yet.
  draftCreated,

  /// The local draft has unsaved in-memory edits.
  draftModified,

  /// The draft has been saved locally and matches Cloud or is synced.
  draftSynced,

  /// Draft is ready or modified, requiring test execution before qualification.
  testRequired,

  /// Full progressive test ladder passed locally; ready for cloud publication.
  testsPassed,

  /// Operator cannot publish due to missing permissions or a missing signer.
  publicationUnavailable,

  /// A Profile release has been published and assigned to the Testing channel.
  publishedTesting,

  /// The Profile release is actively assigned to the Beta channel.
  beta,

  /// The Profile release is actively assigned to the Stable channel.
  stable;

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
        WorkerLifecycleStatus.publishedTesting => 'Published (Testing)',
        WorkerLifecycleStatus.beta => 'Beta Rollout',
        WorkerLifecycleStatus.stable => 'Stable Rollout',
      };
}

/// Description of the recommended operator next action.
class WorkerNextAction {
  const WorkerNextAction({
    required this.title,
    required this.description,
    required this.actionLabel,
    required this.subView,
    this.area = LabArea.workers,
  });

  final String title;
  final String description;
  final String actionLabel;
  final WorkerSubView subView;
  final LabArea area;
}

/// Presentation and read model representing the unified UX state of the
/// currently selected logical Worker and its Tool Profile lifecycle.
class SelectedWorkerState {
  const SelectedWorkerState({
    required this.workerTypeId,
    required this.displayName,
    required this.description,
    required this.providerToolName,
    required this.catalogReleaseStage,
    required this.lifecycleState,
    required this.visibilityState,
    required this.capabilities,
    required this.sortOrder,
    required this.profileDefinitionId,
    required this.definitionDisplayName,
    required this.definitionStatus,
    required this.testingVersion,
    required this.betaVersion,
    required this.stableVersion,
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
    required this.releaseCount,
    required this.status,
    required this.nextAction,
  });

  final String workerTypeId;
  final String displayName;
  final String description;
  final String providerToolName;
  final String catalogReleaseStage;
  final String lifecycleState;
  final String visibilityState;
  final List<String> capabilities;
  final int sortOrder;

  final String? profileDefinitionId;
  final String? definitionDisplayName;
  final String? definitionStatus;

  final String testingVersion;
  final String betaVersion;
  final String stableVersion;

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
  final int releaseCount;
  final WorkerLifecycleStatus status;
  final WorkerNextAction nextAction;

  /// Returns a concise operator status string like "Stable v3", "Testing v1", "Draft", or "No Profile".
  String get conciseProfileStatus {
    if (stableVersion != 'None') {
      return 'Stable v$stableVersion';
    }
    if (betaVersion != 'None') {
      return 'Beta v$betaVersion';
    }
    if (testingVersion != 'None') {
      return 'Testing v$testingVersion';
    }
    if (hasLocalDraft) {
      final v = localDraftVersion ?? 1;
      return 'Draft v$v';
    }
    if (profileDefinitionId == null || profileDefinitionId!.isEmpty) {
      return 'No Profile';
    }
    return 'No Profile';
  }

  /// Creates a unified [SelectedWorkerState] from [ProfileLabController] state.
  factory SelectedWorkerState.fromController(ProfileLabController controller) {
    final worker = controller.selectedCloudWorker;
    if (worker == null) {
      return SelectedWorkerState._empty();
    }

    final workerTypeId = worker['workerTypeId'] as String? ?? '';
    final displayName = worker['displayName'] as String? ?? workerTypeId;
    final description =
        worker['description'] as String? ?? 'No description provided.';
    final catalogReleaseStage = worker['releaseStage'] as String? ?? 'testing';
    final lifecycleState = worker['lifecycleState'] as String? ?? 'active';
    final visibilityState = worker['visibilityState'] as String? ?? 'visible';
    final rawCaps = worker['capabilities'] as List?;
    final capabilities = rawCaps != null
        ? List<String>.unmodifiable(rawCaps.map((c) => c.toString()))
        : const <String>[];
    final sortOrder = (worker['sortOrder'] as num?)?.toInt() ?? 100;

    final profileDefId = worker['profileDefinitionId'] as String? ??
        controller.selectedDefinitionId;
    final definition = controller.selectedCloudDefinition;
    final defDisplayName = definition?['displayName'] as String?;
    final defStatus = definition?['status'] as String?;

    final channels =
        (definition?['channels'] as Map?)?.cast<String, dynamic>() ?? {};
    final stableVersion = channels['stable']?.toString() ?? 'None';
    final betaVersion = channels['beta']?.toString() ?? 'None';
    final testingVersion = channels['testing']?.toString() ?? 'None';

    final draft = controller.currentDraft;
    final hasLocalDraft = draft != null;
    final localDraftVersion = draft?.releaseVersion;
    final localDraftDigest = draft?.payloadDigest;
    final isDraftDirty = controller.isDirty;
    final draftAlreadyPublished = draft != null &&
        controller.cloudReleases.any((release) =>
            release['releaseVersion'] == draft.releaseVersion &&
            release['lifecycleState'] != 'draft' &&
            release['lifecycleState'] != 'revoked' &&
            release['payloadDigest'] == draft.payloadDigest);
    final syncState = controller.syncState;

    final cloudDraftExists = controller.cloudDraftExists ?? false;
    final cloudDraftVersion = controller.cloudDraftVersion;
    final cloudDraftDigest = controller.cloudDigest;

    final providerTool = worker['providerToolName'] as String? ??
        (draft?.profile['providerTool'] as Map?)?['name']?.toString() ??
        '';
    final detectedPath = providerTool.isNotEmpty
        ? controller.detectedProviderPaths[providerTool]
        : null;
    final isProviderDetected = detectedPath != null;

    final isTesting = controller.isTesting;
    final savedQualification = draft != null &&
        controller.currentEvidence.any((evidence) =>
            evidence['profileDefinitionId'] == draft.profileDefinitionId &&
            evidence['releaseVersion'] == draft.releaseVersion &&
            evidence['profileDigest'] == draft.payloadDigest &&
            ToolProfileAcceptanceEvidence.hasCloudContractShape(evidence,
                profile: draft.profile));
    final lastTestResult = controller.testResultMatchesDraft
        ? controller.lastTestResult
        : savedQualification
            ? 'pass'
            : controller.lastTestResult;
    final testStatusMessage = controller.testStatusMessage;

    final canPublish = controller.canPublish;
    String? publicationBlockReason;
    if (!canPublish) {
      if (controller.labAccess?.releaseManager != true) {
        publicationBlockReason = 'Release Manager role required to publish.';
      } else if (controller.labAccess?.signerReady != true) {
        publicationBlockReason = 'Cloud Profile Signer key is unavailable.';
      } else {
        publicationBlockReason = 'Unauthorized to publish releases.';
      }
    }

    final releaseCount = controller.cloudReleases.length;

    // Compute explicit lifecycle status
    final WorkerLifecycleStatus status;
    final WorkerNextAction nextAction;

    if (profileDefId == null || profileDefId.isEmpty) {
      status = WorkerLifecycleStatus.noProfile;
      nextAction = const WorkerNextAction(
        title: 'Create Profile Definition',
        description:
            'This logical Worker has no Tool Profile definition configured.',
        actionLabel: 'Configure Profile',
        subView: WorkerSubView.draftAndTest,
      );
    } else if (!hasLocalDraft && releaseCount == 0) {
      status = WorkerLifecycleStatus.noProfile;
      nextAction = WorkerNextAction(
        title: 'Create Initial Draft',
        description:
            'No local draft or published release exists for this Worker.',
        actionLabel: controller.hasStarterTemplate
            ? 'Create Initial Draft'
            : 'Create blank Profile',
        subView: WorkerSubView.draftAndTest,
      );
    } else if (isDraftDirty) {
      status = WorkerLifecycleStatus.draftModified;
      nextAction = const WorkerNextAction(
        title: 'Save Unsaved Changes',
        description:
            'You have modified the local profile draft. Save it locally before testing.',
        actionLabel: 'Review & Save Draft',
        subView: WorkerSubView.draftAndTest,
      );
    } else if (hasLocalDraft &&
        !draftAlreadyPublished &&
        lastTestResult != 'pass') {
      status = WorkerLifecycleStatus.testRequired;
      nextAction = const WorkerNextAction(
        title: 'Test the Local Profile',
        description:
            'The draft is saved but has not been qualified through the local test ladder.',
        actionLabel: 'Run Profile Tests',
        subView: WorkerSubView.draftAndTest,
      );
    } else if (hasLocalDraft &&
        !draftAlreadyPublished &&
        lastTestResult == 'pass' &&
        !canPublish) {
      status = WorkerLifecycleStatus.publicationUnavailable;
      nextAction = WorkerNextAction(
        title: 'Publication Unavailable',
        description: publicationBlockReason ??
            'Draft passed local tests, but signing and publishing are unavailable in this session.',
        actionLabel: 'Inspect Access',
        subView: WorkerSubView.overview,
      );
    } else if (hasLocalDraft &&
        !draftAlreadyPublished &&
        lastTestResult == 'pass' &&
        canPublish) {
      status = WorkerLifecycleStatus.testsPassed;
      nextAction = const WorkerNextAction(
        title: 'Publish to Testing',
        description:
            'Local qualification passed! Publish this release to Cloud and sign with the Tool Profile key.',
        actionLabel: 'Publish to Testing',
        subView: WorkerSubView.draftAndTest,
      );
    } else if (stableVersion != 'None') {
      status = WorkerLifecycleStatus.stable;
      nextAction = const WorkerNextAction(
        title: 'Stable Rollout Active',
        description:
            'This Worker has an active Stable Profile release serving workspaces.',
        actionLabel: 'Inspect Workspaces',
        subView: WorkerSubView.releases,
        area: LabArea.workspaces,
      );
    } else if (betaVersion != 'None') {
      status = WorkerLifecycleStatus.beta;
      nextAction = const WorkerNextAction(
        title: 'Promote to Stable',
        description:
            'Beta qualification in progress. Verify evidence and promote to Stable.',
        actionLabel: 'Inspect Releases',
        subView: WorkerSubView.releases,
      );
    } else if (testingVersion != 'None') {
      status = WorkerLifecycleStatus.publishedTesting;
      nextAction = const WorkerNextAction(
        title: 'Promote to Beta',
        description:
            'Release is published on the Testing channel. Promote to Beta for broader rollout.',
        actionLabel: 'Promote Release',
        subView: WorkerSubView.releases,
      );
    } else if (hasLocalDraft) {
      status = WorkerLifecycleStatus.draftSynced;
      nextAction = const WorkerNextAction(
        title: 'Test the Local Profile',
        description: 'Run the test ladder to verify CLI compatibility.',
        actionLabel: 'Run Profile Tests',
        subView: WorkerSubView.draftAndTest,
      );
    } else {
      status = WorkerLifecycleStatus.noProfile;
      nextAction = const WorkerNextAction(
        title: 'Configure Profile',
        description: 'Initialize a Tool Profile draft for this Worker.',
        actionLabel: 'Configure Draft',
        subView: WorkerSubView.draftAndTest,
      );
    }

    return SelectedWorkerState(
      workerTypeId: workerTypeId,
      displayName: displayName,
      description: description,
      providerToolName: providerTool,
      catalogReleaseStage: catalogReleaseStage,
      lifecycleState: lifecycleState,
      visibilityState: visibilityState,
      capabilities: capabilities,
      sortOrder: sortOrder,
      profileDefinitionId: profileDefId,
      definitionDisplayName: defDisplayName,
      definitionStatus: defStatus,
      testingVersion: testingVersion,
      betaVersion: betaVersion,
      stableVersion: stableVersion,
      hasLocalDraft: hasLocalDraft,
      localDraftVersion: localDraftVersion,
      localDraftDigest: localDraftDigest,
      isDraftDirty: isDraftDirty,
      syncState: syncState,
      cloudDraftExists: cloudDraftExists,
      cloudDraftVersion: cloudDraftVersion,
      cloudDraftDigest: cloudDraftDigest,
      providerDetectedPath: detectedPath,
      isProviderDetected: isProviderDetected,
      isTesting: isTesting,
      lastTestResult: lastTestResult,
      testStatusMessage: testStatusMessage,
      canPublish: canPublish,
      publicationBlockReason: publicationBlockReason,
      releaseCount: releaseCount,
      status: status,
      nextAction: nextAction,
    );
  }

  factory SelectedWorkerState._empty() {
    return const SelectedWorkerState(
      workerTypeId: '',
      displayName: '',
      description: '',
      providerToolName: '',
      catalogReleaseStage: 'testing',
      lifecycleState: 'inactive',
      visibilityState: 'hidden',
      capabilities: [],
      sortOrder: 100,
      profileDefinitionId: null,
      definitionDisplayName: null,
      definitionStatus: null,
      testingVersion: 'None',
      betaVersion: 'None',
      stableVersion: 'None',
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
      releaseCount: 0,
      status: WorkerLifecycleStatus.noSelection,
      nextAction: WorkerNextAction(
        title: 'Select a Worker',
        description: 'Choose a logical Worker from the catalog on the left.',
        actionLabel: 'Select Worker',
        subView: WorkerSubView.overview,
      ),
    );
  }
}
