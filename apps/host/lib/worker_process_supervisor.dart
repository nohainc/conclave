import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'platform_runtime.dart';
import 'worker_diagnostic_store.dart';
import 'worker_launch_environment.dart';
import 'worker_release_verifier.dart';

/// Workspace-owned process boundary for a native Worker executable.
///
/// A process is created for one assignment or candidate check. Provider tools,
/// arguments, and session identifiers stay inside the Worker executable.
final class WorkerProcessSupervisor {
  WorkerProcessSupervisor({
    PlatformRuntime? platformRuntime,
    this.maxStderrBytes = 64 * 1024,
    this.maxFrameBytes = WorkerProtocolLimits.maxFrameBytes,
  }) : _platformRuntime = platformRuntime ?? currentPlatformRuntime;

  final PlatformRuntime _platformRuntime;
  final int maxStderrBytes;
  final int maxFrameBytes;
  final Map<String, Process> _activeAssignments = {};
  final Set<String> _cancelledAssignments = {};

  /// Cancels an assignment by terminating its Workspace-owned process tree.
  Future<void> cancel(String assignmentId) async {
    final process = _activeAssignments[assignmentId];
    if (process == null) return;
    _cancelledAssignments.add(assignmentId);
    await _terminate(process);
  }

  /// Runs an explicitly requested passive or live Worker probe using the
  /// admitted native executable. Live probes may consume provider quota.
  Future<ProbeResult> probe(
    WorkerReleaseAdmission admission, {
    required Directory stateDirectory,
    required WorkerProbeMode mode,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final timer = Stopwatch()..start();
    Process? process;
    _WorkerChannel? channel;
    var stopped = false;
    try {
      process = await _start(
        admission.executable,
        stateDirectory: stateDirectory,
        workingDirectory: stateDirectory,
      );
      channel = _WorkerChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'probe-init-${DateTime.now().microsecondsSinceEpoch}',
          workerTypeId: admission.manifest.workerTypeId,
          expectedWorkerVersion: admission.manifest.workerVersion,
        ),
        _remaining(timeout, timer),
      );
      if (initialized is! InitializeResult) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'Worker returned an invalid initialize response',
        );
      }
      admission.validateInitializeResult(initialized);
      final result = await channel.exchange(
        ProbeRequest(
          requestId: 'probe-${DateTime.now().microsecondsSinceEpoch}',
          mode: mode,
        ),
        _remaining(timeout, timer),
      );
      if (result is! ProbeResult || result.mode != mode) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'Worker returned an invalid probe response',
        );
      }
      await _stopProcess(process, channel, graceful: true);
      stopped = true;
      return result;
    } on TimeoutException {
      throw const WorkerProcessFailure(
        WorkerIssueCode.deadlineExceeded,
        'Worker probe exceeded its deadline',
      );
    } finally {
      if (process != null && !stopped) {
        await _stopProcess(process, channel, graceful: false);
      }
      await channel?.dispose();
    }
  }

  Future<void> validateCandidate(
    WorkerReleaseAdmission admission, {
    required Directory stateDirectory,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final diagnostics = _diagnosticsFor(stateDirectory);
    final workerTypeId = admission.manifest.workerTypeId;
    final workerVersion = admission.manifest.workerVersion;
    final timer = Stopwatch()..start();
    Process? process;
    _WorkerChannel? channel;
    String stage = 'process_start';
    String? errorCode;
    String? toolVersion;
    int? exitCode;
    var processStopped = false;
    final pendingLogs = <Future<void>>[];
    try {
      await _record(diagnostics, workerTypeId, workerVersion, stage,
          'process.start.requested');
      process = await _start(
        admission.executable,
        stateDirectory: stateDirectory,
        workingDirectory: stateDirectory,
      );
      channel = _WorkerChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        onStderrLine: (line) {
          pendingLogs.add(
            diagnostics
                .recordWorkerStderrLine(
                  line,
                  workerTypeId: workerTypeId,
                  workerVersion: workerVersion,
                  protocolStage: stage,
                )
                .catchError((_) {}),
          );
        },
      );
      stage = 'initialize';
      await _record(diagnostics, workerTypeId, workerVersion, stage,
          'protocol.initialize');
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: 'candidate-init',
          workerTypeId: workerTypeId,
          expectedWorkerVersion: workerVersion,
        ),
        _remaining(timeout, timer),
      );
      if (initialized is! InitializeResult) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'Candidate returned an invalid initialize response',
        );
      }
      admission.validateInitializeResult(initialized);
      stage = 'probe';
      await _record(diagnostics, workerTypeId, workerVersion, stage,
          'protocol.probe.passive');
      final probe = await channel.exchange(
        ProbeRequest(
          requestId: 'candidate-passive-probe',
          mode: WorkerProbeMode.passive,
        ),
        _remaining(timeout, timer),
      );
      if (probe is! ProbeResult || probe.mode != WorkerProbeMode.passive) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'Candidate returned an invalid passive probe response',
        );
      }
      if (!probe.ready) {
        throw WorkerProcessFailure(
          probe.issueCode ?? WorkerIssueCode.providerToolUnavailable,
          _safeDiagnostic(probe.diagnostics ?? 'Candidate is not ready'),
        );
      }
      toolVersion = probe.tool?.version;
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'probe.ready',
        providerToolVersion: toolVersion,
        durationMs: timer.elapsedMilliseconds,
      );
      exitCode = await _stopProcess(process, channel, graceful: true);
      processStopped = true;
    } on TimeoutException {
      errorCode = WorkerIssueCode.deadlineExceeded;
      throw WorkerProcessFailure(
        WorkerIssueCode.deadlineExceeded,
        'Candidate initialize or passive probe exceeded its deadline',
      );
    } on WorkerProcessFailure catch (failure) {
      errorCode = failure.issueCode;
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'candidate.failed',
        level: 'error',
        errorCode: errorCode,
        durationMs: timer.elapsedMilliseconds,
      );
      rethrow;
    } on Object catch (failure) {
      errorCode = WorkerIssueCode.workerInternalFailure;
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'candidate.failed',
        level: 'error',
        errorCode: errorCode,
        durationMs: timer.elapsedMilliseconds,
      );
      throw WorkerProcessFailure(
        WorkerIssueCode.workerInternalFailure,
        'Candidate failed during $stage (${failure.runtimeType})',
      );
    } finally {
      if (process != null && !processStopped) {
        exitCode = await _stopProcess(process, channel, graceful: false);
      }
      await channel?.dispose();
      await Future.wait(pendingLogs);
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'process.exited',
        durationMs: timer.elapsedMilliseconds,
        errorCode: errorCode,
        processExitCode: exitCode,
      );
    }
  }

  Future<WorkerProcessResult> execute({
    required File executable,
    required Directory workstreamDirectory,
    required Directory stateDirectory,
    required String workerTypeId,
    required String workerVersion,
    String? providerToolName,
    String? providerToolVersion,
    required ExecuteRequest request,
    void Function(WorkerProgress progress)? onProgress,
  }) async {
    final budget = Duration(milliseconds: request.timeoutMs);
    final timer = Stopwatch()..start();
    final diagnostics = _diagnosticsFor(stateDirectory);
    if (_activeAssignments.containsKey(request.assignmentId)) {
      throw const WorkerProcessFailure(
        WorkerIssueCode.workerInternalFailure,
        'Assignment is already running',
      );
    }
    Process? process;
    _WorkerChannel? channel;
    String stage = 'process_start';
    String? errorCode;
    int? exitCode;
    var processStopped = false;
    var succeeded = false;
    final pendingLogs = <Future<void>>[];
    try {
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'process.start.requested',
        runId: request.assignmentId,
      );
      process = await _start(
        executable,
        stateDirectory: stateDirectory,
        workingDirectory: workstreamDirectory,
      );
      _activeAssignments[request.assignmentId] = process;
      channel = _WorkerChannel(
        process,
        maxFrameBytes: maxFrameBytes,
        maxStderrBytes: maxStderrBytes,
        onStderrLine: (line) {
          final pending = diagnostics.recordWorkerStderrLine(
            line,
            workerTypeId: workerTypeId,
            workerVersion: workerVersion,
            protocolStage: stage,
            runId: request.assignmentId,
          );
          pendingLogs.add(pending.catchError((_) {}));
        },
      );
      stage = 'initialize';
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'protocol.initialize',
        runId: request.assignmentId,
      );
      final initialized = await channel.exchange(
        InitializeRequest(
          requestId: '${request.requestId}-init',
          workerTypeId: workerTypeId,
          expectedWorkerVersion: workerVersion,
        ),
        _remaining(budget, timer),
      );
      if (initialized is! InitializeResult ||
          initialized.workerTypeId != workerTypeId ||
          initialized.workerVersion != workerVersion) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'Worker identity did not match its admitted release',
        );
      }
      stage = 'execute';
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        'protocol.execute',
        runId: request.assignmentId,
      );
      final frame = await channel.exchange(
        request,
        _remaining(budget, timer),
        onProgress: onProgress,
      );
      if (frame is WorkerResult) {
        succeeded = true;
        exitCode = await _stopProcess(process, channel, graceful: true);
        processStopped = true;
        await Future.wait(pendingLogs);
        return WorkerProcessResult(
          result: frame,
        );
      }
      throw const WorkerProcessFailure(
        WorkerIssueCode.workerInternalFailure,
        'Worker returned an unexpected response frame',
      );
    } on TimeoutException {
      errorCode = WorkerIssueCode.deadlineExceeded;
      throw const WorkerProcessFailure(
        WorkerIssueCode.deadlineExceeded,
        'Worker assignment exceeded its deadline',
      );
    } on WorkerProcessFailure catch (failure) {
      if (_cancelledAssignments.contains(request.assignmentId)) {
        errorCode = WorkerIssueCode.cancelled;
        throw const WorkerProcessFailure(
          WorkerIssueCode.cancelled,
          'Worker assignment was cancelled',
        );
      }
      errorCode = failure.issueCode;
      throw WorkerProcessFailure(
        failure.issueCode,
        _safeDiagnostic(failure.safeDiagnostic),
        failureKind: failure.failureKind,
        retrySafe: failure.retrySafe ||
            (stage != 'execute' && failure.isWorkerReleaseFailure),
      );
    } on FileSystemException {
      errorCode = WorkerIssueCode.permissionDenied;
      throw const WorkerProcessFailure(
        WorkerIssueCode.permissionDenied,
        'Worker could not access a required local file or directory',
      );
    } on Object {
      errorCode = WorkerIssueCode.workerInternalFailure;
      throw WorkerProcessFailure(
        WorkerIssueCode.workerInternalFailure,
        'Worker process failed',
        failureKind: stage == 'process_start'
            ? WorkerRuntimeFailureKind.processCrash
            : WorkerRuntimeFailureKind.internalWorkerError,
        retrySafe: stage != 'execute',
      );
    } finally {
      _activeAssignments.remove(request.assignmentId);
      _cancelledAssignments.remove(request.assignmentId);
      if (process != null && !processStopped) {
        exitCode = await _stopProcess(process, channel, graceful: false);
      }
      await channel?.dispose();
      await Future.wait(pendingLogs);
      await _record(
        diagnostics,
        workerTypeId,
        workerVersion,
        stage,
        succeeded ? 'assignment.completed' : 'assignment.failed',
        level: succeeded ? 'info' : 'error',
        runId: request.assignmentId,
        providerToolName: providerToolName,
        providerToolVersion: providerToolVersion,
        durationMs: timer.elapsedMilliseconds,
        errorCode: errorCode,
        processExitCode: exitCode,
      );
    }
  }

  Future<Process> _start(
    File executable, {
    required Directory stateDirectory,
    required Directory workingDirectory,
  }) async {
    if (!executable.isAbsolute || !await executable.exists()) {
      throw const WorkerProcessFailure(
        WorkerIssueCode.workerInternalFailure,
        'Worker executable is unavailable',
        failureKind: WorkerRuntimeFailureKind.processCrash,
        retrySafe: true,
      );
    }
    await stateDirectory.create(recursive: true);
    if (!workingDirectory.isAbsolute || !await workingDirectory.exists()) {
      throw const WorkerProcessFailure(
        WorkerIssueCode.permissionDenied,
        'Workstream directory is unavailable',
      );
    }
    final environment = _workerEnvironment();
    return _platformRuntime.startIsolatedProcess(
      executable.path,
      const [],
      workingDirectory: workingDirectory.path,
      environment: {
        ...environment,
        'CONCLAVE_WORKER_STATE_DIR': stateDirectory.path,
      },
      includeParentEnvironment: false,
    );
  }

  Future<void> _terminate(Process process) async {
    try {
      await _platformRuntime.terminateProcessTree(process, force: true);
    } on Object {
      process.kill(ProcessSignal.sigkill);
    }
  }

  WorkerDiagnosticStore _diagnosticsFor(Directory stateDirectory) =>
      WorkerDiagnosticStore(
        directory: Directory(
          '${stateDirectory.parent.path}${Platform.pathSeparator}logs',
        ),
      );

  Future<void> _record(
    WorkerDiagnosticStore store,
    String workerTypeId,
    String workerVersion,
    String stage,
    String event, {
    String level = 'info',
    String? runId,
    String? providerToolName,
    String? providerToolVersion,
    int? durationMs,
    String? errorCode,
    int? processExitCode,
  }) async {
    try {
      await store.record(
        workerTypeId: workerTypeId,
        workerVersion: workerVersion,
        protocolStage: stage,
        event: event,
        level: level,
        runId: runId,
        providerToolName: providerToolName,
        providerToolVersion: providerToolVersion,
        durationMs: durationMs,
        errorCode: errorCode,
        processExitCode: processExitCode,
      );
    } on Object {
      // Diagnostics must never interrupt a Worker assignment.
    }
  }

  Future<int?> _stopProcess(
    Process process,
    _WorkerChannel? channel, {
    required bool graceful,
  }) async {
    if (graceful) await channel?.closeInput();
    int? exitCode;
    if (graceful) {
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // Escalate to process-tree cleanup below.
      }
    }
    if (exitCode == null) {
      await _terminate(process);
      try {
        exitCode = await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        exitCode = null;
      }
    }
    try {
      await channel?.waitForStderr().timeout(const Duration(seconds: 1));
    } on TimeoutException {
      // Preserve bounded completion if a descendant kept stderr open.
    }
    return exitCode;
  }

  Map<String, String> _workerEnvironment() {
    final parent = Map<String, String>.from(Platform.environment);
    final home = parent['HOME'] ??
        parent['USERPROFILE'] ??
        _platformRuntime.homeDirectory;
    if (_platformRuntime.isWindows) {
      parent.putIfAbsent('USERPROFILE', () => home);
    } else {
      parent.putIfAbsent('HOME', () => home);
    }
    final temp = parent['TMPDIR'] ??
        parent['TMP'] ??
        parent['TEMP'] ??
        Directory.systemTemp.path;
    parent.putIfAbsent('TMPDIR', () => temp);
    parent.putIfAbsent('TMP', () => temp);
    parent.putIfAbsent('TEMP', () => temp);
    return safeWorkerEnvironment(
      const {},
      parentEnvironment: parent,
      operatingSystem: _platformRuntime.operatingSystem,
    );
  }

  Duration _remaining(Duration budget, Stopwatch timer) {
    final value = budget - timer.elapsed;
    if (value <= Duration.zero) throw TimeoutException('Worker deadline');
    return value;
  }

  String _safeDiagnostic(String value) {
    final redacted = value
        .replaceAll(
          RegExp(r'(bearer\s+)[a-z0-9._~+/-]+=*', caseSensitive: false),
          r'$1[REDACTED]',
        )
        .replaceAll(
          RegExp(
            r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|password|authorization|secret)\s*[:=]\s*)[^\s,;]+''',
            caseSensitive: false,
          ),
          r'$1[REDACTED]',
        );
    return redacted.length <= 256 ? redacted : redacted.substring(0, 256);
  }
}

final class WorkerProcessResult {
  const WorkerProcessResult({required this.result});

  final WorkerResult result;
}

final class WorkerProcessFailure implements Exception {
  const WorkerProcessFailure(
    this.issueCode,
    this.safeDiagnostic, {
    WorkerRuntimeFailureKind? failureKind,
    this.retrySafe = false,
  }) : _failureKind = failureKind;

  final String issueCode;
  final String safeDiagnostic;
  final WorkerRuntimeFailureKind? _failureKind;
  final bool retrySafe;

  WorkerRuntimeFailureKind get failureKind =>
      _failureKind ?? workerRuntimeFailureKind(issueCode);

  bool get isWorkerReleaseFailure =>
      failureKind != WorkerRuntimeFailureKind.providerOrUserFailure;

  @override
  String toString() => 'WorkerProcessFailure($issueCode)';
}

enum WorkerRuntimeFailureKind {
  processCrash,
  protocolViolation,
  internalWorkerError,
  providerOrUserFailure,
}

WorkerRuntimeFailureKind workerRuntimeFailureKind(String issueCode) {
  if (issueCode == WorkerIssueCode.malformedFrame ||
      issueCode == WorkerIssueCode.protocolVersionUnsupported ||
      issueCode == WorkerIssueCode.workerTypeMismatch ||
      issueCode == WorkerIssueCode.workerVersionMismatch ||
      issueCode == WorkerIssueCode.stateSchemaIncompatible) {
    return WorkerRuntimeFailureKind.protocolViolation;
  }
  if (issueCode == WorkerIssueCode.workerInternalFailure) {
    return WorkerRuntimeFailureKind.internalWorkerError;
  }
  return WorkerRuntimeFailureKind.providerOrUserFailure;
}

final class _WorkerChannel {
  _WorkerChannel(
    this.process, {
    required this.maxFrameBytes,
    this.maxStderrBytes = 64 * 1024,
    this.onStderrLine,
  }) {
    _stdout = StreamIterator<String>(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    _stderrSubscription = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(_onStderrLine, onDone: _stderrDone.complete);
  }

  final Process process;
  final int maxFrameBytes;
  final int maxStderrBytes;
  final void Function(String jsonLine)? onStderrLine;
  late final StreamIterator<String> _stdout;
  late final StreamSubscription<String> _stderrSubscription;
  final Completer<void> _stderrDone = Completer<void>();
  var _stderrBytesSeen = 0;
  var _stderrTruncationReported = false;

  void _onStderrLine(String line) {
    _stderrBytesSeen += utf8.encode(line).length + 1;
    if (_stderrBytesSeen <= maxStderrBytes &&
        line.length <= WorkerProtocolLimits.maxDiagnosticLength) {
      onStderrLine?.call(line);
    } else if (!_stderrTruncationReported) {
      _stderrTruncationReported = true;
      onStderrLine?.call(
        '{"level":"warning","event":"worker.stderr.truncated"}',
      );
    }
  }

  Future<void> closeInput() async {
    await process.stdin.close();
  }

  Future<void> waitForStderr() => _stderrDone.future;

  Future<WorkerFrame> exchange(
    WorkerFrame request,
    Duration timeout, {
    void Function(WorkerProgress progress)? onProgress,
  }) =>
      _exchange(request, onProgress: onProgress).timeout(timeout);

  Future<WorkerFrame> _exchange(
    WorkerFrame request, {
    void Function(WorkerProgress progress)? onProgress,
  }) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    while (true) {
      final available = await _stdout.moveNext();
      if (!available) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.workerInternalFailure,
          'Worker exited before completing the request',
          failureKind: WorkerRuntimeFailureKind.processCrash,
        );
      }
      final line = _stdout.current;
      if (utf8.encode(line).length > maxFrameBytes) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.malformedFrame,
          'Worker frame exceeded the protocol limit',
        );
      }
      late final WorkerFrame frame;
      try {
        frame = decodeWorkerFrame(line);
      } on FormatException {
        throw const WorkerProcessFailure(
          WorkerIssueCode.malformedFrame,
          'Worker returned a malformed protocol frame',
        );
      }
      if (frame.requestId != request.requestId) {
        throw const WorkerProcessFailure(
          WorkerIssueCode.malformedFrame,
          'Worker response request ID did not match',
        );
      }
      if (frame is WorkerProgress) {
        onProgress?.call(frame);
        continue;
      }
      if (frame is WorkerErrorFrame) {
        throw WorkerProcessFailure(frame.code, frame.message);
      }
      return frame;
    }
  }

  Future<void> dispose() async {
    await _stdout.cancel();
    await _stderrSubscription.cancel();
  }
}
