import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_protocol/conclave_protocol.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'cloud_connection.dart';
import 'runtime_capabilities.dart';
import 'workstream_directory.dart';

Future<void> _materializeWorkRequestInputs({
  required Directory workstreamDirectory,
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
  final root = Directory(
      '${workstreamDirectory.path}${Platform.pathSeparator}.conclave');
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

/// Provider-independent guidance attached to every Workstream execution.
/// It describes the local directory contract without exposing paths or
/// turning Git operations into a Conclave-managed subsystem.
const workstreamExecutionGuidance = <String>[
  'This directory is the Workstream persistent isolated working area.',
  'Reuse existing files and repositories when they are present.',
  'Clone repositories here when the requested work needs one.',
  'Do not assume this directory is disposable; preserve useful local state.',
  'Use normal Git safety practices for fetch, branch, commit, and push.',
  'For parallel Workstreams using one repository, prefer a dedicated branch per Workstream.',
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

class AssignmentLogicalWorker {
  const AssignmentLogicalWorker({
    required this.id,
    required this.workerTypeId,
    required this.enabled,
    required this.ready,
    required this.permissions,
    required this.localConcurrencyLimit,
    this.providerCliVersion,
  });

  final String id;
  final String workerTypeId;
  final bool enabled;
  final bool ready;
  final Set<String> permissions;
  final int localConcurrencyLimit;
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
    this.defaultWorkingDirectory,
    this.workstreamDirectoryLifecycle,
    WorkstreamMutationCoordinator? workstreamMutationCoordinator,
    this.onProgress,
    this.cancelToolProfileAssignment,
  }) : workstreamMutationCoordinator = workstreamMutationCoordinator ??
            (workstreamDirectoryLifecycle == null
                ? null
                : WorkstreamMutationCoordinator(workstreamDirectoryLifecycle));

  final AssignmentLogicalWorkerResolver resolveLogicalWorker;
  final ToolProfileAssignmentExecutor? executeWithToolProfile;
  final Directory? defaultWorkingDirectory;
  final WorkstreamDirectoryLifecycle? workstreamDirectoryLifecycle;
  final WorkstreamMutationCoordinator? workstreamMutationCoordinator;
  final WorkerProgressRelay? onProgress;
  final Future<bool> Function(String assignmentId)? cancelToolProfileAssignment;

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
    final projectId = _requiredStringForWorkstream(
        context.payload['projectId'], 'projectId', executionClass);
    final workstreamId = _requiredStringForWorkstream(
        context.payload['workstreamId'], 'workstreamId', executionClass);
    var directory = defaultWorkingDirectory ?? Directory.current;
    if (projectId != null && workstreamId != null) {
      final lifecycle = workstreamDirectoryLifecycle;
      if (lifecycle == null) {
        throw const RuntimeViolation(
            'Workstream directory lifecycle is required for scoped execution');
      }
      directory = await lifecycle.ensureForExecution(
        projectId: projectId,
        workstreamId: workstreamId,
      );
      await _materializeWorkRequestInputs(
        workstreamDirectory: directory,
        payload: context.payload,
      );
    }
    return WorkerAssignmentScope(worker: worker, workingDirectory: directory);
  }

  Future<WorkspaceAssignmentResult> call(
      WorkspaceAssignmentContext context) async {
    final scope = await prepareAssignmentScope(context);
    final worker = scope.worker;
    final workerId = worker.id;
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
      final workerPayload = _withCorrelation(context.payload, context);
      final profileExecutor = executeWithToolProfile;
      if (profileExecutor == null) {
        throw StateError('Tool Profile Engine assignment runner is required');
      }
      final engineResult = await profileExecutor(
        worker,
        scope.workingDirectory,
        context,
        workerPayload,
        onProgress: onProgress == null
            ? null
            : (progress) => onProgress!(context, progress),
      );
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

    if (context.payload['executionClass'] != 'stateful_workstream') {
      return execute();
    }
    final projectId = context.payload['projectId'];
    final workstreamId = context.payload['workstreamId'];
    final leaseId = context.payload['leaseId'];
    final fencingToken = context.payload['fencingToken'];
    final coordinator = workstreamMutationCoordinator;
    if (projectId is! String ||
        workstreamId is! String ||
        leaseId is! String ||
        fencingToken is! int) {
      throw const RuntimeViolation(
          'stateful assignment requires Workstream lease identity');
    }
    if (coordinator == null) {
      throw const RuntimeViolation(
          'Workstream mutation coordinator is required for stateful execution');
    }
    return coordinator.withMutation(
      projectId: projectId,
      workstreamId: workstreamId,
      leaseId: leaseId,
      fencingToken: fencingToken,
      action: (_) => execute(),
    );
  }

  String? _requiredStringForWorkstream(
      Object? value, String field, Object? executionClass) {
    if (value == null && executionClass != 'stateful_workstream') return null;
    if (value is! String || value.trim().isEmpty) {
      throw RuntimeViolation(
          'execution assignment field $field is required for Workstream CWD');
    }
    return value;
  }

  Future<bool> cancel(String assignmentId, String reason) =>
      cancelToolProfileAssignment?.call(assignmentId) ?? Future.value(false);

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
          if (payload['projectId'] is String) 'projectId': payload['projectId'],
          if (payload['workstreamId'] is String)
            'workstreamId': payload['workstreamId'],
          if (payload['workRequestId'] is String)
            'workRequestId': payload['workRequestId'],
          'workstreamExecutionGuidance': workstreamExecutionGuidance,
        },
      };
}

typedef WorkerProgressRelay = FutureOr<void> Function(
  WorkspaceAssignmentContext context,
  WorkerProgress progress,
);
