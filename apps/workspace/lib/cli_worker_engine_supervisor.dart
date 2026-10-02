import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'platform_runtime.dart';
import 'tool_profile_release_verifier.dart';
import 'cloud_connection.dart';

const cliWorkerEngineVersion = '1.0.0';

/// Runs one isolated generic Engine process for one passive or live probe.
final class CliWorkerEngineSupervisor {
  CliWorkerEngineSupervisor({
    required this.engineExecutable,
    this.engineArgumentsPrefix = const [],
    this.environmentOverrides = const {},
    PlatformRuntime? platformRuntime,
    this.maxFrameBytes = WorkerProtocolLimits.maxFrameBytes,
    this.maxStderrBytes = 64 * 1024,
  }) : _platformRuntime = platformRuntime ?? currentPlatformRuntime;

  final String engineExecutable;
  final List<String> engineArgumentsPrefix;
  final Map<String, String> environmentOverrides;
  final PlatformRuntime _platformRuntime;
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

  Future<ProbeResult> probe(
    ToolProfileReleaseAdmission release, {
    required File profileFile,
    required Directory stateDirectory,
    required WorkerProbeMode mode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final boundedTimeout = timeout >
            const Duration(
              milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs,
            )
        ? const Duration(milliseconds: WorkerProtocolLimits.maxProbeTimeoutMs)
        : timeout;
    if (boundedTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
          timeout, 'timeout', 'probe timeout is too short');
    }
    await stateDirectory.create(recursive: true);
    final timer = Stopwatch()..start();
    Process? process;
    _CliEngineChannel? channel;
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
        environment: environmentOverrides,
        includeParentEnvironment: true,
      );
      channel = _CliEngineChannel(
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
          profileReleaseVersion: release.releaseVersion.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(boundedTimeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion !=
              release.releaseVersion.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion'] ||
          !_sameCapabilities(initialized.capabilities, release.profile)) {
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
            'CLI Worker Engine probe response mismatch');
      }
      if (result.providerToolName != null &&
          result.providerToolName != release.providerToolName) {
        throw const FormatException(
            'CLI Worker Engine provider identity mismatch');
      }
      await process.stdin.close();
      final exitCode =
          await process.exitCode.timeout(const Duration(seconds: 2));
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
    } on ProcessException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
      );
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      await channel?.dispose();
    }
  }

  /// Executes one assignment through an admitted signed Tool Profile.
  Future<WorkerResult> execute(
    ToolProfileReleaseAdmission release, {
    required File profileFile,
    required Directory stateDirectory,
    required Directory workingDirectory,
    required String workerId,
    required int maxConcurrentAssignments,
    required String assignmentId,
    required String prompt,
    required Duration timeout,
    WorkerSessionPolicy sessionPolicy = WorkerSessionPolicy.stateless,
    String? sessionKey,
    String? model,
    WorkerExecutionPolicy executionPolicy = WorkerExecutionPolicy.restricted,
    void Function(WorkerProgress progress)? onProgress,
  }) async {
    if (maxConcurrentAssignments < 1) {
      throw ArgumentError.value(
        maxConcurrentAssignments,
        'maxConcurrentAssignments',
      );
    }
    await stateDirectory.create(recursive: true);
    await workingDirectory.create(recursive: true);
    final timer = Stopwatch()..start();
    Process? process;
    _CliEngineChannel? channel;
    var stopped = false;
    await _acquire(workerId, assignmentId, maxConcurrentAssignments);
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
        workingDirectory: workingDirectory.path,
        environment: environmentOverrides,
        includeParentEnvironment: true,
      );
      _activeAssignments[assignmentId] = process;
      _activeWorkerByAssignment[assignmentId] = workerId;
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: WorkerIssueCode.cancelled,
          message: 'Worker assignment was cancelled.',
        );
      }
      channel = _CliEngineChannel(
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
          profileReleaseVersion: release.releaseVersion.toString(),
          profileDigest: release.payloadDigest,
        ),
        _remaining(timeout, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != release.logicalWorkerTypeId ||
          initialized.engineVersion != cliWorkerEngineVersion ||
          initialized.profileDefinitionId != release.profileDefinitionId ||
          initialized.profileReleaseVersion !=
              release.releaseVersion.toString() ||
          initialized.profileSchemaVersion !=
              release.profile['schemaVersion'] ||
          !_sameCapabilities(initialized.capabilities, release.profile)) {
        throw const FormatException('CLI Worker Engine initialize mismatch');
      }
      final requestId =
          'engine-execute-${DateTime.now().microsecondsSinceEpoch}';
      final result = await channel.exchangeUntilTerminal(
        ExecuteRequest(
          requestId: requestId,
          assignmentId: assignmentId,
          prompt: prompt,
          timeoutMs: timeout.inMilliseconds,
          sessionPolicy: sessionPolicy,
          sessionKey: sessionKey,
          model: model,
          executionPolicy: executionPolicy,
        ),
        _remaining(timeout, timer),
        onProgress: onProgress,
      );
      if (result is WorkerErrorFrame) {
        throw AssignmentExecutionFailure(
          code: result.code,
          message: result.message,
          retryable: result.retryable,
          localDiagnostic: result.diagnostics,
        );
      }
      if (result is! WorkerResult || result.assignmentId != assignmentId) {
        throw const FormatException('CLI Worker Engine execution mismatch');
      }
      await process.stdin.close();
      final exitCode =
          await process.exitCode.timeout(const Duration(seconds: 2));
      if (exitCode != 0) {
        throw const FormatException('CLI Worker Engine exited unsuccessfully');
      }
      stopped = true;
      return result;
    } on TimeoutException {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: WorkerIssueCode.cancelled,
          message: 'Worker assignment was cancelled.',
        );
      }
      throw const AssignmentExecutionFailure(
        code: WorkerIssueCode.deadlineExceeded,
        message: 'Worker assignment exceeded its deadline.',
      );
    } on ProcessException {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: WorkerIssueCode.cancelled,
          message: 'Worker assignment was cancelled.',
        );
      }
      throw const AssignmentExecutionFailure(
        code: WorkerIssueCode.providerToolUnavailable,
        message: 'CLI Worker Engine could not be started.',
      );
    } on Object {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const AssignmentExecutionFailure(
          code: WorkerIssueCode.cancelled,
          message: 'Worker assignment was cancelled.',
        );
      }
      rethrow;
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
      }
      if (identical(_activeAssignments[assignmentId], process)) {
        _activeAssignments.remove(assignmentId);
      }
      _activeWorkerByAssignment.remove(assignmentId);
      _reservedAssignmentIds.remove(assignmentId);
      _reservedWorkerByAssignment.remove(assignmentId);
      _cancelledAssignments.remove(assignmentId);
      await channel?.dispose();
      _release(workerId);
    }
  }

  Future<bool> cancel(String assignmentId) async {
    final queued = _queuedAssignments.remove(assignmentId);
    if (queued != null) {
      _waitersByWorker[queued.workerId]?.remove(queued);
      _cancelledAssignments.add(assignmentId);
      if (!queued.permit.isCompleted) queued.permit.complete();
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

  Future<void> _acquire(String workerId, String assignmentId, int limit) async {
    if (_activeAssignments.containsKey(assignmentId) ||
        _reservedAssignmentIds.contains(assignmentId) ||
        _queuedAssignments.containsKey(assignmentId)) {
      throw const AssignmentExecutionFailure(
        code: 'execution_failed',
        message: 'Assignment is already running.',
      );
    }
    if ((_activeByWorker[workerId] ?? 0) < limit) {
      _reservedAssignmentIds.add(assignmentId);
      _reservedWorkerByAssignment[assignmentId] = workerId;
      _activeByWorker.update(workerId, (value) => value + 1, ifAbsent: () => 1);
      return;
    }
    final queued = _QueuedEngineAssignment(workerId, assignmentId);
    _waitersByWorker.putIfAbsent(workerId, () => []).add(queued);
    _queuedAssignments[assignmentId] = queued;
    await queued.permit.future;
    if (_cancelledAssignments.remove(assignmentId)) {
      throw const AssignmentExecutionFailure(
        code: WorkerIssueCode.cancelled,
        message: 'Worker assignment was cancelled.',
      );
    }
    _reservedAssignmentIds.add(assignmentId);
    _reservedWorkerByAssignment[assignmentId] = workerId;
  }

  void _release(String workerId) {
    final waiters = _waitersByWorker[workerId];
    while (waiters != null && waiters.isNotEmpty) {
      final next = waiters.removeAt(0);
      _queuedAssignments.remove(next.assignmentId);
      if (next.permit.isCompleted) continue;
      _reservedAssignmentIds.add(next.assignmentId);
      _reservedWorkerByAssignment[next.assignmentId] = workerId;
      next.permit.complete();
      return;
    }
    if (waiters != null && waiters.isEmpty) _waitersByWorker.remove(workerId);
    final active = (_activeByWorker[workerId] ?? 1) - 1;
    if (active <= 0) {
      _activeByWorker.remove(workerId);
    } else {
      _activeByWorker[workerId] = active;
    }
  }

  Duration _remaining(Duration timeout, Stopwatch timer) {
    final value = timeout - timer.elapsed;
    if (value <= Duration.zero) {
      throw TimeoutException('probe deadline elapsed');
    }
    return value;
  }

  bool _sameCapabilities(List<String> values, Map<String, Object?> profile) {
    final raw = profile['capabilities'];
    if (raw is! List || raw.length != values.length) return false;
    return values.toSet().length == values.length &&
        values.toSet().containsAll(
              raw.whereType<String>(),
            );
  }
}

final class _QueuedEngineAssignment {
  _QueuedEngineAssignment(this.workerId, this.assignmentId);

  final String workerId;
  final String assignmentId;
  final Completer<void> permit = Completer<void>();
}

final class CliWorkerEngineProbeException implements Exception {
  const CliWorkerEngineProbeException(this.issueCode, this.safeMessage);

  final String issueCode;
  final String safeMessage;
}

final class _CliEngineChannel {
  _CliEngineChannel(
    this.process, {
    required this.maxFrameBytes,
    required this.maxStderrBytes,
  }) : _lines = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
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
      throw TimeoutException('CLI Worker Engine closed its protocol stream');
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
        throw TimeoutException('CLI Worker Engine closed its protocol stream');
      }
      final line = _lines.current;
      if (utf8.encode(line).length > maxFrameBytes) {
        throw const FormatException(
            'CLI Worker Engine frame exceeds the limit');
      }
      final frame = decodeWorkerFrame(line);
      if (frame.requestId != request.requestId) {
        throw const FormatException('CLI Worker Engine request ID mismatch');
      }
      if (frame is WorkerProgress) {
        if (frame.assignmentId != request.assignmentId) {
          throw const FormatException(
              'CLI Worker Engine assignment ID mismatch');
        }
        onProgress?.call(frame);
        continue;
      }
      if (frame is WorkerResult || frame is WorkerErrorFrame) {
        if (frame is WorkerResult &&
                frame.assignmentId != request.assignmentId ||
            frame is WorkerErrorFrame &&
                frame.assignmentId != request.assignmentId) {
          throw const FormatException(
              'CLI Worker Engine assignment ID mismatch');
        }
        return frame;
      }
      throw const FormatException(
          'CLI Worker Engine returned an invalid frame');
    }
  }

  Future<void> _drainStderr() async {
    await for (final bytes in process.stderr) {
      _stderrBytes =
          (_stderrBytes + bytes.length).clamp(0, maxStderrBytes).toInt();
      // Continue draining after the diagnostic cap; raw provider/engine text
      // is intentionally not retained or returned to the UI.
    }
  }

  Future<void> dispose() async {
    await _lines.cancel();
    await _stderrTask;
  }
}
