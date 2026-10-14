import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'cloud_connection.dart';
import 'runtime_capabilities.dart';
import 'space_directory.dart';
import 'thread_directory.dart';

/// Translate assignment policy without consulting names or providers.
///
/// Full local access is a local Workspace decision. The assignment may request
/// it, but it is accepted only when the persisted host-owner authorization for
/// the selected Worker is present.
WorkerExecutionPolicy assignmentExecutionPolicy(
  Map<String, Object?> payload, {
  bool fullAccessAuthorized = false,
}) {
  final requested = payload['executionPolicy'];
  if (requested == 'full_access') {
    if (!fullAccessAuthorized) {
      throw const AssignmentExecutionFailure(
        code: 'permission_denied',
        message: 'Full local access is not authorized for this Worker.',
      );
    }
    return WorkerExecutionPolicy.fullAccess;
  }
  if (requested != null &&
      requested != 'restricted' &&
      requested != 'provider_default') {
    throw const AssignmentExecutionFailure(
      code: 'permission_denied',
      message: 'The requested execution policy is not supported.',
    );
  }
  // A read-only assignment must stay provider-controlled even when the local
  // Worker is authorized for Full Local Access. `stateless_read` by itself is
  // not enough to force the read-only policy: some one-shot Work requests are
  // stateless while still allowing repository and shell operations.
  if (payload['readOnly'] == true) {
    return WorkerExecutionPolicy.providerDefault;
  }
  if (requested == 'provider_default') {
    return WorkerExecutionPolicy.providerDefault;
  }
  if (requested == 'restricted') {
    return WorkerExecutionPolicy.restricted;
  }
  // Once the owner has enabled Full Local Access for this Worker, ordinary
  // non-read-only assignments inherit it unless Cloud explicitly asks for a
  // narrower policy. This keeps old assignment payloads working while making
  // the local setting effective.
  if (fullAccessAuthorized) return WorkerExecutionPolicy.fullAccess;
  return payload['executionClass'] == 'stateless_read'
      ? WorkerExecutionPolicy.providerDefault
      : WorkerExecutionPolicy.restricted;
}

Future<void> _materializeWorkRequestInputs({
  required Directory threadDirectory,
  required Map<String, Object?> payload,
}) async {
  final rawRequestId = payload['workRequestId'];
  final inputValue = payload['input'];
  if (inputValue is! Map || inputValue['attachments'] is! List) return;
  final attachments = inputValue['attachments'] as List;
  if (attachments.length > 10) {
    throw StateError('too many Work Request attachments');
  }
  if (rawRequestId is! String ||
      !RegExp(r'^work-request-[0-9a-f-]{36}$').hasMatch(rawRequestId)) {
    if (attachments.any((value) => value is Map && value['kind'] == 'file')) {
      throw StateError('invalid Work Request attachment scope');
    }
    return;
  }
  final root =
      Directory('${threadDirectory.path}${Platform.pathSeparator}.conclave');
  final inputs = Directory('${root.path}${Platform.pathSeparator}inputs');
  final requestDirectory =
      Directory('${inputs.path}${Platform.pathSeparator}$rawRequestId');
  for (final directory in [root, inputs, requestDirectory]) {
    final type =
        await FileSystemEntity.type(directory.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw StateError('unsafe Work Request input directory');
    }
    if (type == FileSystemEntityType.notFound) await directory.create();
  }
  var totalBytes = 0;
  for (var index = 0; index < attachments.length; index++) {
    final value = attachments[index];
    if (value is! Map || value['kind'] != 'file') continue;
    final encoded = value['contentBase64'];
    if (encoded is! String || encoded.length > 2 * 1024 * 1024) {
      throw StateError('invalid Work Request file input');
    }
    late final List<int> bytes;
    try {
      bytes = base64.decode(encoded);
    } on FormatException {
      throw StateError('invalid Work Request file input');
    }
    if (bytes.length > 1024 * 1024 || value['sizeBytes'] != bytes.length) {
      throw StateError('Work Request file input exceeds size limits');
    }
    totalBytes += bytes.length;
    if (totalBytes > 1024 * 1024) {
      throw StateError('Work Request file inputs exceed total size limit');
    }
    final target = File(
        '${requestDirectory.path}${Platform.pathSeparator}file-${(index + 1).toString().padLeft(3, '0')}');
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw StateError('unsafe Work Request input file');
    }
    if (type == FileSystemEntityType.file) {
      final existing = await target.readAsBytes();
      if (existing.length != bytes.length ||
          !List<int>.generate(bytes.length, (i) => existing[i] ^ bytes[i])
              .every((value) => value == 0)) {
        throw StateError('Work Request input changed across assignment retry');
      }
    } else {
      await target.writeAsBytes(bytes, flush: true);
    }
  }
}

/// Provider-independent guidance attached to every Space execution.
/// It describes the local directory contract without exposing paths or
/// turning Git operations into a Conclave-managed subsystem.
const threadExecutionGuidance = <String>[
  'This directory is the Space persistent working area shared by its Threads.',
  'Reuse existing files and repositories when they are present.',
  'Clone repositories here when the requested work needs one.',
  'Do not assume this directory is disposable; preserve useful local state.',
  'Use normal Git safety practices for fetch, branch, commit, and push.',
  'For parallel Threads using one repository, prefer a dedicated branch per Thread.',
  'Fetch before integrating remote changes.',
  'Commit and push meaningful state before moving work to another physical Workspace.',
  'Use Workspace-local Git, SSH, or provider CLI authentication for private repositories.',
];

typedef AssignmentLogicalWorkerResolver = FutureOr<AssignmentLogicalWorker?>
    Function(String workerId);
typedef ToolProfileAssignmentExecutor = Future<WorkerResult> Function(
  AssignmentLogicalWorker worker,
  Directory workingDirectory,
  WorkspaceAssignmentContext context,
  Map<String, Object?> payload, {
  void Function(WorkerProgress progress)? onProgress,
});

typedef ToolProfileActivityAssignmentExecutor = Future<WorkerResult> Function(
  AssignmentLogicalWorker worker,
  Directory workingDirectory,
  WorkspaceAssignmentContext context,
  Map<String, Object?> payload, {
  void Function(WorkerProgress progress)? onProgress,
  FutureOr<void> Function()? onSlotReserved,
  FutureOr<bool> Function()? authorizeStart,
  void Function()? onEngineProcessStarted,
  FutureOr<void> Function(WorkerActivity activity)? onActivity,
});
typedef WorkerExecutionStartedRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
);
typedef WorkerExecutionSlotReservedRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
);
typedef WorkerExecutionStartAuthorizer = FutureOr<bool> Function(
  WorkspaceAssignmentContext context,
);
typedef WorkerEngineProcessStartedRelay = void Function(
  WorkspaceAssignmentContext context,
);

class AssignmentLogicalWorker {
  const AssignmentLogicalWorker({
    required this.id,
    required this.workerTypeId,
    required this.enabled,
    required this.ready,
    required this.permissions,
    required this.localConcurrencyLimit,
    this.fullLocalAccessAuthorized = false,
    this.providerCliVersion,
  });

  final String id;
  final String workerTypeId;
  final bool enabled;
  final bool ready;
  final Set<String> permissions;
  final int localConcurrencyLimit;
  final bool fullLocalAccessAuthorized;
  final String? providerCliVersion;
}

class WorkerAssignmentScope {
  const WorkerAssignmentScope({
    required this.worker,
    required this.workingDirectory,
  });

  final AssignmentLogicalWorker worker;
  final Directory workingDirectory;
}

class WorkerAssignmentHandler {
  WorkerAssignmentHandler({
    required this.resolveLogicalWorker,
    this.executeWithToolProfile,
    this.executeWithActivity,
    this.defaultWorkingDirectory,
    this.applicationStateDirectory,
    this.spaceDirectoryLifecycle,
    SpaceMutationCoordinator? spaceMutationCoordinator,
    this.threadDirectoryLifecycle,
    ThreadMutationCoordinator? threadMutationCoordinator,
    this.onProgress,
    this.onActivity,
    this.onExecutionStarted,
    this.onExecutionSlotReserved,
    this.authorizeExecutionStart,
    this.onEngineProcessStarted,
    this.cancelToolProfileAssignment,
  })  : spaceMutationCoordinator = spaceMutationCoordinator ??
            (spaceDirectoryLifecycle == null
                ? null
                : SpaceMutationCoordinator(
                    lifecycle: spaceDirectoryLifecycle,
                    applicationStateDirectory: applicationStateDirectory ??
                        Directory(
                            '${Directory.current.path}${Platform.pathSeparator}.conclave-mutation-state'),
                  )),
        threadMutationCoordinator = threadMutationCoordinator ??
            (threadDirectoryLifecycle == null
                ? null
                : ThreadMutationCoordinator(threadDirectoryLifecycle));

  final AssignmentLogicalWorkerResolver resolveLogicalWorker;
  final ToolProfileAssignmentExecutor? executeWithToolProfile;
  final ToolProfileActivityAssignmentExecutor? executeWithActivity;
  final Directory? defaultWorkingDirectory;
  final Directory? applicationStateDirectory;
  final SpaceDirectoryLifecycle? spaceDirectoryLifecycle;
  final SpaceMutationCoordinator? spaceMutationCoordinator;
  final ThreadDirectoryLifecycle? threadDirectoryLifecycle;
  final ThreadMutationCoordinator? threadMutationCoordinator;
  final WorkerProgressRelay? onProgress;
  final WorkerActivityRelay? onActivity;
  final WorkerExecutionStartedRelay? onExecutionStarted;
  final WorkerExecutionSlotReservedRelay? onExecutionSlotReserved;
  final WorkerExecutionStartAuthorizer? authorizeExecutionStart;
  final WorkerEngineProcessStartedRelay? onEngineProcessStarted;
  final Future<bool> Function(String assignmentId)? cancelToolProfileAssignment;
  final _cancellationRequests = <String>{};

  /// Resolves the local Logical Worker and Workspace-owned execution directory.
  Future<WorkerAssignmentScope> prepareAssignmentScope(
      WorkspaceAssignmentContext context) async {
    final workerId = context.payload['workerId'];
    if (workerId is! String || workerId.isEmpty) {
      throw StateError('assignment workerId is required');
    }
    final worker = await resolveLogicalWorker(workerId);
    final expectedWorkerTypeId = context.payload['workerTypeId'];
    if (expectedWorkerTypeId is! String ||
        expectedWorkerTypeId.isEmpty ||
        worker == null ||
        worker.id != workerId ||
        worker.workerTypeId != expectedWorkerTypeId ||
        !worker.enabled ||
        !worker.ready) {
      throw const AssignmentExecutionFailure(
        code: 'worker_not_ready',
        message: 'Worker is not ready for assignments.',
      );
    }
    if (worker.localConcurrencyLimit < 1) {
      throw StateError('local Worker concurrency limit must be positive');
    }
    rejectWorkerControlledPaths(context.payload);
    final executionClass = context.payload['executionClass'];
    final spaceId = _requiredStringForThread(
        context.payload['spaceId'], 'spaceId', executionClass);
    _requiredStringForThread(
        context.payload['threadId'], 'threadId', executionClass);
    var directory = defaultWorkingDirectory ?? Directory.current;
    if (spaceId != null) {
      final spaceLifecycle = spaceDirectoryLifecycle;
      if (spaceLifecycle != null) {
        directory = await spaceLifecycle.ensureForExecution(
          spaceId: spaceId,
          spaceName: _spaceName(context.payload),
        );
      } else {
        final legacyLifecycle = threadDirectoryLifecycle;
        if (legacyLifecycle == null) {
          throw const RuntimeViolation(
              'Space directory lifecycle is required for scoped execution');
        }
        final threadId = _requiredStringForThread(
            context.payload['threadId'], 'threadId', executionClass);
        if (threadId == null) {
          throw const RuntimeViolation(
              'Thread ID is required for legacy scoped execution');
        }
        directory = await legacyLifecycle.ensureForExecution(
          spaceId: spaceId,
          threadId: threadId,
        );
      }
      await _materializeWorkRequestInputs(
        threadDirectory: directory,
        payload: context.payload,
      );
    }
    return WorkerAssignmentScope(worker: worker, workingDirectory: directory);
  }

  Future<WorkspaceAssignmentResult> call(
      WorkspaceAssignmentContext context) async {
    if (_cancellationRequests.remove(context.assignmentId)) {
      throw const AssignmentExecutionFailure(
        code: 'cancelled',
        message: 'The assignment was cancelled before Engine launch.',
      );
    }
    final scope = await prepareAssignmentScope(context);
    final worker = scope.worker;
    final workerId = worker.id;
    // Validate the policy before any provider process is started. This keeps
    // Cloud payloads from elevating a local Worker by themselves.
    assignmentExecutionPolicy(
      context.payload,
      fullAccessAuthorized: worker.fullLocalAccessAuthorized,
    );
    if (worker.fullLocalAccessAuthorized &&
        !worker.permissions.containsAll(const {
          'repository:read',
          'repository:write',
          'shell:execute',
          'network:use',
        })) {
      throw const AssignmentExecutionFailure(
        code: 'permission_denied',
        message: 'Full local access permissions are incomplete.',
      );
    }
    final allowed = worker.permissions;
    if (context.payload['permissionSnapshot'] != null) {
      validateAssignmentScope(
        context.payload,
        localWorkerPermissions: allowed,
      );
    }
    final requestedPermissions = context.payload['permissions'];
    if (requestedPermissions != null) {
      if (requestedPermissions is! List ||
          requestedPermissions.any((item) => item is! String)) {
        throw AssignmentExecutionFailure(
          code: 'permission_denied',
          message: executionErrorMessage('permission_denied'),
        );
      }
      final denied = requestedPermissions.whereType<String>().firstWhere(
          (permission) => !runtimePermissionAllowed(permission, allowed),
          orElse: () => '');
      if (denied.isNotEmpty) {
        throw AssignmentExecutionFailure(
          code: 'permission_denied',
          message: executionErrorMessage('permission_denied'),
        );
      }
    }
    Future<WorkspaceAssignmentResult> execute() async {
      if (_cancellationRequests.remove(context.assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: 'cancelled',
          message: 'The assignment was cancelled before Engine launch.',
        );
      }
      final workerPayload = _withCorrelation(context.payload, context);
      final profileExecutor = executeWithToolProfile;
      final activityProfileExecutor = executeWithActivity;
      if (profileExecutor == null && activityProfileExecutor == null) {
        throw StateError('Tool Profile Engine assignment runner is required');
      }
      var startupRelay = Future<void>.value();
      void relayProgress(WorkerProgress progress) {
        if (progress.message == workerProviderExecutionStartedMessage) {
          final started = onExecutionStarted;
          if (started != null) {
            startupRelay = startupRelay.then(
              (_) => Future<void>.sync(() => started(context)),
            );
          }
          return;
        }
        onProgress?.call(context, progress);
      }

      final engineResult = activityProfileExecutor != null
          ? await activityProfileExecutor(
              worker,
              scope.workingDirectory,
              context,
              workerPayload,
              onProgress: relayProgress,
              onSlotReserved: onExecutionSlotReserved == null
                  ? null
                  : () => onExecutionSlotReserved!(context),
              authorizeStart: authorizeExecutionStart == null
                  ? null
                  : () => authorizeExecutionStart!(context),
              onEngineProcessStarted: onEngineProcessStarted == null
                  ? null
                  : () => onEngineProcessStarted!(context),
              onActivity: onActivity == null
                  ? null
                  : (activity) => onActivity!(context, activity),
            )
          : await profileExecutor!(
              worker,
              scope.workingDirectory,
              context,
              workerPayload,
              onProgress: relayProgress,
            );
      await startupRelay;
      if (_cancellationRequests.remove(context.assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: 'cancelled',
          message: 'The assignment was cancelled before terminal delivery.',
        );
      }
      final output = {
        'summary': engineResult.output.isEmpty
            ? 'Worker $workerId completed assignment'
            : engineResult.output,
        'output': {'text': engineResult.output},
        'artifactIds': engineResult.artifacts,
      };
      final summary = output['summary'];
      final nestedOutput = output['output'];
      return WorkspaceAssignmentResult(
        summary: summary is String && summary.isNotEmpty
            ? summary
            : 'Worker $workerId completed assignment',
        output: nestedOutput is Map
            ? Map<String, Object?>.from(nestedOutput)
            : output,
        artifactIds: output['artifactIds'] is List
            ? (output['artifactIds'] as List).whereType<String>().toList()
            : const [],
      );
    }

    if (context.payload['executionClass'] != 'stateful_thread') {
      return execute();
    }
    final spaceId = context.payload['spaceId'];
    final threadId = context.payload['threadId'];
    final leaseId = context.payload['leaseId'];
    final fencingToken = context.payload['fencingToken'];
    if (spaceId is! String ||
        threadId is! String ||
        leaseId is! String ||
        fencingToken is! int) {
      throw const RuntimeViolation(
          'stateful assignment requires Thread lease identity');
    }
    final spaceCoordinator = spaceMutationCoordinator;
    if (spaceCoordinator != null) {
      return spaceCoordinator.withMutation(
        spaceId: spaceId,
        threadId: threadId,
        spaceName: _spaceName(context.payload),
        leaseId: leaseId,
        fencingToken: fencingToken,
        action: (_) => execute(),
      );
    }
    final legacyCoordinator = threadMutationCoordinator;
    if (legacyCoordinator == null) {
      throw const RuntimeViolation(
          'Space mutation coordinator is required for stateful execution');
    }
    return legacyCoordinator.withMutation(
      spaceId: spaceId,
      threadId: threadId,
      leaseId: leaseId,
      fencingToken: fencingToken,
      action: (_) => execute(),
    );
  }

  String _spaceName(Map<String, Object?> payload) {
    final value = payload['spaceName'];
    return value is String && value.trim().isNotEmpty ? value.trim() : 'Space';
  }

  String? _requiredStringForThread(
      Object? value, String field, Object? executionClass) {
    if (value == null && executionClass != 'stateful_thread') return null;
    if (value is! String || value.trim().isEmpty) {
      throw RuntimeViolation(
          'execution assignment field $field is required for Thread CWD');
    }
    return value;
  }

  Future<bool> cancel(String assignmentId, String reason) async {
    _cancellationRequests.add(assignmentId);
    final cancel = cancelToolProfileAssignment;
    if (cancel == null) return true;
    final cancelled = await cancel(assignmentId);
    if (cancelled) _cancellationRequests.remove(assignmentId);
    return cancelled || _cancellationRequests.contains(assignmentId);
  }

  bool isCancellationRequested(String assignmentId) =>
      _cancellationRequests.contains(assignmentId);

  Map<String, Object?> _withCorrelation(
    Map<String, Object?> payload,
    WorkspaceAssignmentContext context,
  ) =>
      {
        ...payload,
        'conclave': {
          'workspaceId': context.workspaceId,
          'workspaceRuntimeId': context.workspaceRuntimeId,
          'workerId': context.workerId,
          'runId': context.runId,
          'taskId': context.taskId,
          'attemptId': context.attemptId,
          'assignmentId': context.assignmentId,
          'idempotencyKey': context.idempotencyKey,
          if (payload['spaceId'] is String) 'spaceId': payload['spaceId'],
          if (payload['threadId'] is String) 'threadId': payload['threadId'],
          if (payload['workRequestId'] is String)
            'workRequestId': payload['workRequestId'],
          'threadExecutionGuidance': threadExecutionGuidance,
        },
      };
}

typedef WorkerProgressRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
  WorkerProgress progress,
);

typedef WorkerActivityRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
  WorkerActivity activity,
);
