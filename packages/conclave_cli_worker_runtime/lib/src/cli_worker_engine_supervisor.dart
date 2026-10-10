import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'platform_process_supervisor.dart';
import 'worker_process_cleanup.dart';

const cliWorkerEngineVersion = '1.0.0';

/// Runs one isolated generic Engine process for one passive or live probe,
/// or for normal / sandbox assignment execution.
final class CliWorkerEngineSupervisor {
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
        final pid = record['pid'];
        final executable = record['executable'];
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
        if (command.isNotEmpty &&
            command.startsWith('$executable ') &&
            command.contains(stateDirectory)) {
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
    } on ProcessException {
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
      );
    } finally {
      if (process != null && !stopped) {
        await _platformRuntime.terminateProcessTree(process, force: true);
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
    WorkerSessionPolicy sessionPolicy = WorkerSessionPolicy.stateless,
    String? sessionKey,
    WorkerSessionContext? workerSession,
    ConversationBootstrap? statelessContext,
    String? model,
    String? reasoningEffort,
    WorkerExecutionPolicy executionPolicy = WorkerExecutionPolicy.restricted,
    Duration? engineExecutionTimeout,
    void Function()? onExecutionStarted,
    void Function(WorkerProgress progress)? onProgress,
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
    final requestedEngineTimeout = engineExecutionTimeout ?? boundedTimeout;
    final boundedEngineTimeout =
        requestedEngineTimeout >
            const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        ? const Duration(milliseconds: WorkerProtocolLimits.maxTimeoutMs)
        : requestedEngineTimeout;

    if (boundedTimeout < const Duration(milliseconds: 100) ||
        boundedEngineTimeout < const Duration(milliseconds: 100)) {
      throw ArgumentError.value(
        engineExecutionTimeout ?? timeout,
        'timeout',
        'assignment timeout is too short',
      );
    }
    await stateDirectory.create(recursive: true);
    await workingDirectory.create(recursive: true);

    await _acquireSlot(workerId, assignmentId, maxConcurrentAssignments);
    final timer = Stopwatch()..start();
    Process? process;
    File? processRecord;
    CliEngineChannel? channel;
    var stopped = false;
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
          executionPolicy: executionPolicy,
        ),

        _remaining(boundedTimeout, timer),
        onProgress: (progress) {
          if (progress.message == workerProviderExecutionStartedMessage) {
            onExecutionStarted?.call();
          } else {
            onProgress?.call(progress);
          }
        },
      );
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
        throw const FormatException('CLI Worker Engine exited unsuccessfully');
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
    } on ProcessException {
      if (_cancelledAssignments.remove(assignmentId)) {
        throw const WorkerAssignmentCancelledException();
      }
      throw const CliWorkerEngineProbeException(
        WorkerIssueCode.providerToolUnavailable,
        'CLI Worker Engine could not be started.',
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
      await _deleteProcessRecord(processRecord);
      await channel?.dispose();
    }
  }

  Future<bool> cancel(String assignmentId) async {
    final queued = _queuedAssignments.remove(assignmentId);
    if (queued != null) {
      final workerId = queued.workerId;
      _waitersByWorker[workerId]?.remove(queued);
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

  Future<void> _acquireSlot(
    String workerId,
    String assignmentId,
    int maxConcurrentAssignments,
  ) async {
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
    await queued.permit.future;
    _reservedAssignmentIds.add(assignmentId);
    _reservedWorkerByAssignment[assignmentId] = workerId;
  }

  void _releaseSlot(String workerId, String assignmentId) {
    final waiters = _waitersByWorker[workerId];
    if (waiters != null && waiters.isNotEmpty) {
      final next = waiters.removeAt(0);
      _queuedAssignments.remove(next.assignmentId);
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

  bool _sameCapabilities(List<String> values, Map<String, Object?> profile) {
    final raw = profile['capabilities'];
    if (raw is! List || raw.length != values.length) return false;
    return values.toSet().length == values.length &&
        values.toSet().containsAll(raw.whereType<String>());
  }

  Future<File?> _writeProcessRecord(
    Process process, {
    required String assignmentId,
    required Directory stateDirectory,
  }) async {
    final directory = processRegistryDirectory;
    if (directory == null) return null;
    await directory.create(recursive: true);
    final safeId = base64Url
        .encode(utf8.encode(assignmentId))
        .replaceAll('=', '');
    final file = File('${directory.path}/$safeId.worker-process.json');
    await file.writeAsString(
      jsonEncode({
        'pid': process.pid,
        'executable': File(engineExecutable).absolute.path,
        'stateDirectory': stateDirectory.absolute.path,
      }),
      flush: true,
    );
    return file;
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
}
