import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'platform_process_supervisor.dart';
import 'worker_process_cleanup.dart';

const cliWorkerEngineVersion = '1.3.0';

/// Runs one isolated generic Engine process for one passive or live probe,
/// or for normal / sandbox assignment execution.
final class CliWorkerEngineSupervisor {
  static const defaultQueueWaitTimeout = Duration(minutes: 2);

  CliWorkerEngineSupervisor({
    required this.engineExecutable,
    this.engineArgumentsPrefix = const [],
    this.environmentOverrides = const {},
    this.processRegistryDirectory,
    PlatformProcessSupervisor? platformRuntime,
    this.maxFrameBytes = WorkerProtocolLimits.maxFrameBytes,
    this.maxStderrBytes = 64 * 1024,
  }) : _platformRuntime = platformRuntime ?? const StandardProcessSupervisor();

  final String engineExecutable;
  final List<String> engineArgumentsPrefix;
  final Map<String, String> environmentOverrides;
  final Directory? processRegistryDirectory;
  final PlatformProcessSupervisor _platformRuntime;
  final int maxFrameBytes;
  final int maxStderrBytes;
  final Map<String, Process> _activeAssignments = {};
  final Map<String, String> _activeWorkerByAssignment = {};
  final Map<String, String> _reservedWorkerByAssignment = {};
  final Map<String, int> _activeByWorker = {};
  final Map<String, List<_QueuedEngineAssignment>> _waitersByWorker = {};
  final Map<String, _QueuedEngineAssignment> _queuedAssignments = {};
  final Set<String> _reservedAssignmentIds = {};
  final Set<String> _cancelledAssignments = {};

  /// Reaps Engine processes left behind if the owning Workspace Service died.
  /// A PID is acted on only when its command line still identifies this exact
  /// bundled Engine and its private state directory.
  Future<int> recoverOrphanedProcesses() async {
    final directory = processRegistryDirectory;
    if (directory == null || !await directory.exists()) return 0;
    if (Platform.isWindows) return 0;
    try {
      final probe = await Process.run('ps', ['-p', '1', '-o', 'pid=']);
      if (probe.exitCode != 0) return 0;
    } on ProcessException {
      return 0;
    }
    var reaped = 0;
    for (final entity in await directory.list(followLinks: false).toList()) {
      if (entity is! File || !entity.path.endsWith('.worker-process.json')) {
        continue;
      }
      try {
        final decoded = jsonDecode(await entity.readAsString());
        if (decoded is! Map) throw const FormatException('invalid record');
        final record = Map<String, Object?>.from(decoded);
        final pid = record['enginePid'] ?? record['pid'];
        final executable = record['engineExecutable'] ?? record['executable'];
        final stateDirectory = record['stateDirectory'];
        if (pid is! int ||
            pid <= 1 ||
            executable != File(engineExecutable).absolute.path ||
            stateDirectory is! String) {
          throw const FormatException('invalid process identity');
        }
        final processInfo = await Process.run('ps', [
          '-p',
          '$pid',
          '-o',
          'command=',
        ]);
        final command = processInfo.exitCode == 0
            ? processInfo.stdout.toString().trimLeft()
            : '';
        final recordedStartIdentity = record['engineStartIdentity'];
        String? currentStartIdentity;
        if (recordedStartIdentity is String &&
            recordedStartIdentity.isNotEmpty) {
          final startInfo = await Process.run('ps', [
            '-p',
            '$pid',
            '-o',
            'lstart=',
          ]);
          currentStartIdentity = startInfo.exitCode == 0
              ? startInfo.stdout.toString().trim()
              : null;
        }
        if (command.isNotEmpty &&
            command.startsWith('$executable ') &&
            command.contains(stateDirectory) &&
            (recordedStartIdentity == null ||
                recordedStartIdentity == currentStartIdentity)) {
          await const WorkerProcessCleanup().terminateOrphanedPid(pid);
          reaped++;
        }
      } on Object {
        // Stale, malformed, or reused PIDs are discarded without signaling.
      }
      try {
        await entity.delete();
      } on FileSystemException {
        // A later startup will retry the bounded cleanup.
      }
    }
    return reaped;
  }

  Future<ProbeResult> probe(
    ToolProfileCandidate release, {
    required File profileFile,
    required Directory stateDirectory,
    required WorkerProbeMode mode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final boundedTimeout =
        timeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
        : timeout;
    if (boundedTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
        timeout,
        'timeout',
        'probe timeout is too short',
      );
    }
    await stateDirectory.create(recursive: true);
    final timer = Stopwatch()..start();
    Process? process;
    File? processRecord;
    CliEngineChannel? channel;
    var stopped = false;
    try {
      process = await _platformRuntime.startIsolatedProcess(
        engineExecutable,
        [
          ...engineArgumentsPrefix,
          '--profile',
          profileFile.path,
          '--engine-version',
          cliWorkerEngineVersion,
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: stateDirectory.path,
        environment: _engineEnvironment(),
        includeParentEnvironment: false,
      );
      processRecord = await _writeProcessRecord(
        process,
        assignmentId: 'probe-${DateTime.now().microsecondsSinceEpoch}',
        stateDirectory: stateDirectory,
      );
      channel = CliEngineChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'engine-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: release.logicalWorkerTypeId,
          expectedEngineVersion: cliWorkerEngineVersion,
          profileDefinitionId: release.profileDefinitionId,
          profileReleaseVersion: release.revision.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion != release.revision.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion']) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      final result = await channel.exchange(
        ProbeRequest(
          requestId: 'engine-probe-${DateTime.now().microsecondsSinceEpoch}',
          mode: mode,
          timeoutMs: boundedTimeout.inMilliseconds,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (result is! ProbeResult || result.mode != mode) {
        throw const FormatException(
          'CLI Worker Engine probe response mismatch',
        );
      }
      if (result.providerToolName != null &&
          result.providerToolName != release.providerToolName) {
        throw const FormatException(
          'CLI Worker Engine provider identity mismatch',
        );
      }
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      if (exitCode != 0) {
        throw const FormatException('CLI Worker Engine exited unsuccessfully');
      }
      stopped = true;
      return result;
    } on TimeoutException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Provider probe exceeded its deadline.',
      );
    } on ProcessException catch (error) {
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
        localDiagnostics: jsonEncode({
          'stage': 'engine_process_start',
          'errorCode': error.errorCode,
          'message': error.message,
        }),
      );
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      if (processRecord != null) {
        await _updateProcessRecord(
          processRecord,
          engineState: 'terminated',
          providerState: 'terminated',
        );
      }
      await _deleteProcessRecord(processRecord);
      await channel?.dispose();
    }
  }

  /// Executes one assignment through a Tool Profile candidate.
  Future<WorkerResult> execute(
    ToolProfileCandidate release, {
    required File profileFile,
    required Directory stateDirectory,
    required Directory workingDirectory,
    required String workerId,
    required int maxConcurrentAssignments,
    required String assignmentId,
    required String prompt,
    required Duration timeout,
    Duration? queueWaitTimeout,
    WorkerSessionPolicy sessionPolicy = WorkerSessionPolicy.stateless,
    String? sessionKey,
    WorkerSessionContext? workerSession,
    ConversationBootstrap? statelessContext,
    String? model,
    String? reasoningEffort,
    String? catalogRevision,
    WorkerExecutionPolicy executionPolicy = WorkerExecutionPolicy.restricted,
    Duration? engineExecutionTimeout,
    String? attemptId,
    String? executionId,
    FutureOr<void> Function()? onSlotReserved,
    void Function()? onExecutionStarted,
    void Function(WorkerProgress progress)? onProgress,
    FutureOr<void> Function(WorkerActivity activity)? onActivity,
  }) async {
    if (workerSession != null && workerSession.workerId != workerId) {
      throw const FormatException(
        'Worker Session does not belong to this Worker',
      );
    }
    final boundedTimeout =
        timeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : timeout;
    final requestedQueueWaitTimeout =
        queueWaitTimeout ?? defaultQueueWaitTimeout;
    final boundedQueueWaitTimeout =
        requestedQueueWaitTimeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : requestedQueueWaitTimeout;
    final requestedEngineTimeout = engineExecutionTimeout ?? boundedTimeout;
    final boundedEngineTimeout =
        requestedEngineTimeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : requestedEngineTimeout;

    if (boundedTimeout < const Duration(milliseconds: 100) ||
        boundedQueueWaitTimeout < const Duration(milliseconds: 100) ||
        boundedEngineTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
        engineExecutionTimeout ?? timeout,
        'timeout',
        'assignment timeout is too short',
      );
    }
    await stateDirectory.create(recursive: true);
    await workingDirectory.create(recursive: true);

    if (_activeAssignments.containsKey(assignmentId) ||
        _reservedAssignmentIds.contains(assignmentId) ||
        _queuedAssignments.containsKey(assignmentId)) {
      throw const FormatException(
        'Assignment already has an active or queued Engine execution',
      );
    }
    final existingRecord = _processRecordFile(assignmentId);
    if (existingRecord != null && await existingRecord.exists()) {
      throw const FormatException(
        'Assignment already has a durable Engine ownership record',
      );
    }

    // Queueing is admission time, not provider execution time. A request
    // must not lose its provider deadline while waiting for another
    // assignment to release a Worker slot.
    await _acquireSlot(
      workerId,
      assignmentId,
      maxConcurrentAssignments,
      timeout: boundedQueueWaitTimeout,
    );
    await onSlotReserved?.call();
    final timer = Stopwatch()..start();
    Process? process;
    File? processRecord;
    CliEngineChannel? channel;
    var stopped = false;
    var processObservation = Future<void>.value();
    try {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      process = await _platformRuntime.startIsolatedProcess(
        engineExecutable,
        [
          ...engineArgumentsPrefix,
          '--profile',
          profileFile.path,
          '--engine-version',
          cliWorkerEngineVersion,
          '--state-directory',
          stateDirectory.path,
        ],
        workingDirectory: workingDirectory.path,
        environment: _engineEnvironment(),
        includeParentEnvironment: false,
      );
      processRecord = await _writeProcessRecord(
        process,
        assignmentId: assignmentId,
        stateDirectory: stateDirectory,
        workingDirectory: workingDirectory,
        workerId: workerId,
        attemptId: attemptId,
        executionId: executionId,
        deadlineAt: DateTime.now()
            .toUtc()
            .add(_remaining(boundedTimeout, timer))
            .toIso8601String(),
      );
      _activeAssignments[assignmentId] = process;
      _activeWorkerByAssignment[assignmentId] = workerId;
      _reservedAssignmentIds.remove(assignmentId);
      _reservedWorkerByAssignment.remove(assignmentId);
      if (_cancelledAssignments.remove(assignmentId)) {
        await _platformRuntime.terminateProcessTree(process, force: true);
        throw const WorkerAssignmentCancelledException();
      }
      channel = CliEngineChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'engine-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: release.logicalWorkerTypeId,
          expectedEngineVersion: cliWorkerEngineVersion,
          profileDefinitionId: release.profileDefinitionId,
          profileReleaseVersion: release.revision.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion != release.revision.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion']) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      final result = await channel.exchangeUntilTerminal(
        ExecuteRequest(
          requestId: 'engine-exec-${DateTime.now().microsecondsSinceEpoch}',
          assignmentId: assignmentId,
          prompt: prompt,
          timeoutMs: boundedEngineTimeout.inMilliseconds,
          sessionPolicy: sessionPolicy,
          sessionKey: sessionKey,
          workerSession: workerSession,
          statelessContext: statelessContext,
          model: model,
          reasoningEffort: reasoningEffort,
          catalogRevision: catalogRevision,
          executionPolicy: executionPolicy,
        ),

        _remaining(boundedTimeout, timer),
        onProgress: (progress) {
          if (progress.message == workerProviderExecutionStartedMessage) {
            onExecutionStarted?.call();
            final record = processRecord;
            if (record != null) {
              processObservation = processObservation.then(
                (_) => _updateProcessRecord(
                  record,
                  engineState: 'running',
                  providerState: 'running',
                ),
              );
            }
            // The Workspace handler consumes this internal marker to persist
            // and relay the explicit startup acknowledgement. It is never
            // forwarded as user-facing progress.
            onProgress?.call(progress);
          } else {
            onProgress?.call(progress);
          }
        },
        onActivity: onActivity,
      );
      await processObservation;
      if (result is WorkerErrorFrame) {
        throw CliWorkerEngineProbeException(
          result.code,
          result.message,
          localDiagnostics: result.diagnostics,
        );
      }
      if (result is! WorkerResult || result.assignmentId != assignmentId) {
        throw const FormatException(
          'CLI Worker Engine execution response mismatch',
        );
      }
      await process.stdin.close();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 2),
      );
      if (exitCode != 0) {
        throw CliWorkerEngineProbeException(
          WorkerIssueCode.providerFailure,
          'CLI Worker Engine exited unsuccessfully.',
          localDiagnostics: jsonEncode({
            'stage': 'engine_process_exit',
            'processExitCode': exitCode,
          }),
        );
      }
      stopped = true;
      return result;
    } on TimeoutException {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Assignment execution exceeded its deadline.',
      );
    } on ProcessException catch (error) {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      throw CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
        localDiagnostics: jsonEncode({
          'stage': 'engine_process_start',
          'errorCode': error.errorCode,
          'message': error.message,
        }),
      );
    } on Object {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      rethrow;
    } finally {
      _activeAssignments.remove(assignmentId);
      _activeWorkerByAssignment.remove(assignmentId);
      _reservedAssignmentIds.remove(assignmentId);
      _reservedWorkerByAssignment.remove(assignmentId);
      _releaseSlot(workerId, assignmentId);
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      if (processRecord != null) {
        await _updateProcessRecord(
          processRecord,
          engineState: 'terminated',
          providerState: 'terminated',
        );
      }
      await _deleteProcessRecord(processRecord);
      await channel?.dispose();
    }
  }

  Future<bool> cancel(String assignmentId) async {
    final queued = _queuedAssignments.remove(assignmentId);
    if (queued != null) {
      final workerId = queued.workerId;
      _waitersByWorker[workerId]?.remove(queued);
      // A cancelled waiter never received a slot, so it must not release one.
      if (!queued.permit.isCompleted) {
        queued.permit.completeError(const WorkerAssignmentCancelledException());
      }
      return true;
    }
    final process = _activeAssignments[assignmentId];
    if (process == null) {
      if (_reservedAssignmentIds.contains(assignmentId)) {
        _cancelledAssignments.add(assignmentId);
        return true;
      }
      return false;
    }
    _cancelledAssignments.add(assignmentId);
    await _platformRuntime.terminateProcessTree(process, force: true);
    return true;
  }

  Future<void> cancelWorker(String workerId) async {
    final assignmentIds = <String>{
      for (final entry in _queuedAssignments.entries)
        if (entry.value.workerId == workerId) entry.key,
      for (final entry in _activeWorkerByAssignment.entries)
        if (entry.value == workerId) entry.key,
      for (final entry in _reservedWorkerByAssignment.entries)
        if (entry.value == workerId) entry.key,
    };
    for (final assignmentId in assignmentIds) {
      await cancel(assignmentId);
    }
  }

  Future<void> shutdown() async {
    for (final assignmentId in _queuedAssignments.keys.toList()) {
      await cancel(assignmentId);
    }
    final processes = _activeAssignments.values.toList();
    for (final process in processes) {
      await _platformRuntime.terminateProcessTree(process, force: true);
    }
  }

  Future<void> _acquireSlot(
    String workerId,
    String assignmentId,
    int maxConcurrentAssignments, {
    required Duration timeout,
  }) async {
    final active = _activeByWorker[workerId] ?? 0;
    if (active < maxConcurrentAssignments) {
      _activeByWorker[workerId] = active + 1;
      _reservedAssignmentIds.add(assignmentId);
      _reservedWorkerByAssignment[assignmentId] = workerId;
      return;
    }
    final queued = _QueuedEngineAssignment(workerId, assignmentId);
    _queuedAssignments[assignmentId] = queued;
    _waitersByWorker.putIfAbsent(workerId, () => []).add(queued);
    try {
      await queued.permit.future.timeout(timeout);
    } on TimeoutException {
      _queuedAssignments.remove(assignmentId);
      _waitersByWorker[workerId]?.remove(queued);
      if (_waitersByWorker[workerId]?.isEmpty == true) {
        _waitersByWorker.remove(workerId);
      }
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.deadlineExceeded,
        'Assignment execution exceeded its deadline while waiting for a Worker slot.',
      );
    }
    _reservedAssignmentIds.add(assignmentId);
    _reservedWorkerByAssignment[assignmentId] = workerId;
  }

  void _releaseSlot(String workerId, String assignmentId) {
    final waiters = _waitersByWorker[workerId];
    if (waiters != null && waiters.isNotEmpty) {
      final next = waiters.removeAt(0);
      _queuedAssignments.remove(next.assignmentId);
      // Transfer the reservation before completing the waiter. This closes
      // the cancellation race between dequeue and the waiting future's
      // continuation: cancel() can now mark the transferred reservation and
      // the continuation will stop before launching a process.
      _reservedAssignmentIds.add(next.assignmentId);
      _reservedWorkerByAssignment[next.assignmentId] = workerId;
      if (!next.permit.isCompleted) {
        next.permit.complete();
      }
      return;
    }
    final active = _activeByWorker[workerId] ?? 0;
    if (active <= 1) {
      _activeByWorker.remove(workerId);
    } else {
      _activeByWorker[workerId] = active - 1;
    }
  }

  Duration _remaining(Duration timeout, Stopwatch timer) {
    final value = timeout - timer.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('probe deadline elapsed');
    }
    return value;
  }

  Future<File?> _writeProcessRecord(
    Process process, {
    required String assignmentId,
    required Directory stateDirectory,
    Directory? workingDirectory,
    String? workerId,
    String? attemptId,
    String? executionId,
    String? deadlineAt,
  }) async {
    final directory = processRegistryDirectory;
    if (directory == null) return null;
    await directory.create(recursive: true);
    final file = _processRecordFile(assignmentId)!;
    final startedAt = DateTime.now().toUtc();
    final startIdentity = await _processStartIdentity(process.pid);
    final localExecutionId = _localExecutionIdentity();
    await file.writeAsString(
      jsonEncode({
        'schemaVersion': 2,
        'recordId': localExecutionId,
        'localExecutionId': localExecutionId,
        'assignmentId': assignmentId,
        if (attemptId != null) 'attemptId': attemptId,
        if (executionId != null) 'executionId': executionId,
        if (workerId != null) 'workerId': workerId,
        'pid': process.pid,
        'enginePid': process.pid,
        'executable': File(engineExecutable).absolute.path,
        'engineExecutable': File(engineExecutable).absolute.path,
        'stateDirectory': stateDirectory.absolute.path,
        if (workingDirectory != null)
          'workingDirectory': workingDirectory.absolute.path,
        'engineStartedAt': startedAt.toIso8601String(),
        if (startIdentity != null) 'engineStartIdentity': startIdentity,
        if (deadlineAt != null) 'deadlineAt': deadlineAt,
        'engineState': 'running',
        'providerState': 'not_started',
      }),
      flush: true,
    );
    return file;
  }

  Future<void> _updateProcessRecord(
    File file, {
    required String engineState,
    required String providerState,
  }) async {
    try {
      if (!await file.exists()) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return;
      final record = Map<String, Object?>.from(decoded)
        ..['engineState'] = engineState
        ..['providerState'] = providerState
        ..['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      await file.writeAsString(jsonEncode(record), flush: true);
    } on Object {
      // The journal and terminal delivery remain authoritative if diagnostics
      // cannot update during shutdown.
    }
  }

  File? _processRecordFile(String assignmentId) {
    final directory = processRegistryDirectory;
    if (directory == null) return null;
    final safeId = base64Url
        .encode(utf8.encode(assignmentId))
        .replaceAll('=', '');
    return File('${directory.path}/$safeId.worker-process.json');
  }

  Future<String?> _processStartIdentity(int pid) async {
    if (Platform.isWindows) return null;
    try {
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'lstart=']);
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return value.isEmpty ? null : value;
    } on Object {
      return null;
    }
  }

  String _localExecutionIdentity() {
    final suffix = Random.secure().nextInt(0xFFFFFF).toRadixString(16);
    return 'exec-${DateTime.now().toUtc().microsecondsSinceEpoch}-$suffix';
  }

  Future<void> _deleteProcessRecord(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // Leave stale records for safe startup validation and cleanup.
    }
  }

  Map<String, String> _engineEnvironment() {
    const inheritedKeys = {
      'HOME',
      'USER',
      'LOGNAME',
      'SHELL',
      '__CF_USER_TEXT_ENCODING',
      'PATH',
      'TMPDIR',
      'TMP',
      'TEMP',
      'LANG',
      'LC_ALL',
      'LC_CTYPE',
      'XDG_CONFIG_HOME',
      'USERPROFILE',
      'SystemRoot',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'ALL_PROXY',
      'NO_PROXY',
      'SSH_AUTH_SOCK',
      'SSH_AGENT_PID',
      'GIT_CONFIG_GLOBAL',
      'GIT_CONFIG_SYSTEM',
      'GIT_SSH_COMMAND',
      'GIT_ASKPASS',
      'GIT_TERMINAL_PROMPT',
      'SSH_ASKPASS',
      'XDG_DATA_HOME',
      'XDG_CACHE_HOME',
    };
    return {
      for (final key in inheritedKeys)
        if (Platform.environment[key] case final value?) key: value,
      ...environmentOverrides,
    };
  }
}

final class _QueuedEngineAssignment {
  _QueuedEngineAssignment(this.workerId, this.assignmentId);

  final String workerId;
  final String assignmentId;
  final Completer<void> permit = Completer<void>();
}

final class CliWorkerEngineProbeException implements Exception {
  const CliWorkerEngineProbeException(
    this.issueCode,
    this.safeMessage, {
    this.localDiagnostics,
  });

  final String issueCode;
  final String safeMessage;

  /// Bounded protocol diagnostics for local operator investigation.
  /// Never send this field to Cloud or include it in acceptance evidence.
  final String? localDiagnostics;

  @override
  String toString() =>
      'CliWorkerEngineProbeException($issueCode): $safeMessage';
}

final class WorkerAssignmentCancelledException implements Exception {
  const WorkerAssignmentCancelledException();
}

final class CliEngineChannel {
  CliEngineChannel(
    this.process, {
    required this.maxFrameBytes,
    required this.maxStderrBytes,
  }) : _lines = StreamIterator<String>(
         process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
       ) {
    _stderrTask = _drainStderr();
  }

  final Process process;
  final int maxFrameBytes;
  final int maxStderrBytes;
  final StreamIterator<String> _lines;
  late final Future<void> _stderrTask;
  int _stderrBytes = 0;

  Future<WorkerFrame> exchange(WorkerFrame request, Duration timeout) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    if (!await _lines.moveNext().timeout(timeout)) {
      throw await _processExited('engine_initialize');
    }
    final line = _lines.current;
    if (utf8.encode(line).length > maxFrameBytes) {
      throw const FormatException('CLI Worker Engine frame exceeds the limit');
    }
    final frame = decodeWorkerFrame(line);
    if (frame.requestId != request.requestId) {
      throw const FormatException('CLI Worker Engine request ID mismatch');
    }
    return frame;
  }

  Future<WorkerFrame> exchangeUntilTerminal(
    ExecuteRequest request,
    Duration timeout, {
    void Function(WorkerProgress progress)? onProgress,
    FutureOr<void> Function(WorkerActivity activity)? onActivity,
  }) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    final timer = Stopwatch()..start();
    while (true) {
      final remaining = timeout - timer.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('deadline elapsed');
      }
      if (!await _lines.moveNext().timeout(remaining)) {
        throw await _processExited('engine_execute');
      }
      final line = _lines.current;
      if (utf8.encode(line).length > maxFrameBytes) {
        throw const FormatException(
          'CLI Worker Engine frame exceeds the limit',
        );
      }
      final frame = decodeWorkerFrame(line);
      if (frame.requestId != request.requestId) {
        throw const FormatException('CLI Worker Engine request ID mismatch');
      }
      if (frame is WorkerProgress) {
        if (frame.assignmentId != request.assignmentId) {
          throw const FormatException(
            'CLI Worker Engine assignment ID mismatch',
          );
        }
        onProgress?.call(frame);
        continue;
      }
      if (frame is WorkerActivity) {
        if (frame.assignmentId != request.assignmentId) {
          throw const FormatException(
            'CLI Worker Engine assignment ID mismatch',
          );
        }
        final callback = onActivity;
        if (callback != null) {
          await Future.sync(() => callback(frame)).timeout(remaining);
        }
        continue;
      }
      if (frame is WorkerResult || frame is WorkerErrorFrame) {
        if (frame is WorkerResult &&
                frame.assignmentId != request.assignmentId ||
            frame is WorkerErrorFrame &&
                frame.assignmentId != request.assignmentId) {
          throw const FormatException(
            'CLI Worker Engine assignment ID mismatch',
          );
        }
        return frame;
      }
      throw const FormatException(
        'CLI Worker Engine returned an invalid frame',
      );
    }
  }

  Future<void> _drainStderr() async {
    await for (final bytes in process.stderr) {
      _stderrBytes = (_stderrBytes + bytes.length)
          .clamp(0, maxStderrBytes)
          .toInt();
    }
  }

  Future<void> dispose() async {
    await _lines.cancel();
    await _stderrTask;
  }

  Future<Never> _processExited(String stage) async {
    int? exitCode;
    try {
      exitCode = await process.exitCode.timeout(const Duration(seconds: 1));
    } on Object {
      // The process may still be unwinding; the closed stream is already
      // sufficient evidence that this execution cannot produce a result.
    }
    throw CliWorkerEngineProbeException(
      WorkerIssueCode.providerFailure,
      'CLI Worker Engine exited before producing a terminal result.',
      localDiagnostics: jsonEncode({
        'stage': stage,
        if (exitCode != null) 'processExitCode': exitCode,
      }),
    );
  }
}
