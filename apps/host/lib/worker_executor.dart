import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:conclave_protocol/conclave_protocol.dart'
    hide workerProtocolVersion;

import 'cloud_connection.dart';
import 'worker_protocol.dart';
import 'process_tree.dart';
import 'runtime_capabilities.dart';
import 'workstream_directory.dart';
import 'worker_trust_policy.dart';
import 'v7_adapter_protocol.dart';

Map<String, Object?> _safeAdapterProbeConfig(Map<String, Object?> config) => {
      for (final key in const ['endpointUrl', 'organizationId', 'projectId'])
        if (config[key] is String) key: config[key] as String,
    };

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

Object? _redactValue(Object? value, Iterable<String> secrets) {
  if (value is String) return redactSecrets(value, secrets);
  if (value is List) {
    return value.map((item) => _redactValue(item, secrets)).toList();
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key: _redactValue(entry.value, secrets),
    };
  }
  return value;
}

/// Keeps only a small stderr tail for local package-crash diagnostics.
/// Provider output belongs to the package; this is a fallback for a package
/// that exits before it can return a Local Worker Protocol frame.
class _PackageStderrTail {
  _PackageStderrTail();

  static const maxBytes = 768;
  final List<int> _bytes = [];

  void add(List<int> chunk) {
    _bytes.addAll(chunk);
    if (_bytes.length > maxBytes) {
      _bytes.removeRange(0, _bytes.length - maxBytes);
    }
  }

  String readRedacted(Iterable<String> secrets) {
    var value = utf8.decode(_bytes, allowMalformed: true).trim();
    value = redactSecrets(value, secrets);
    // Scrub common credential forms even when they were not supplied as
    // explicit process secrets (for example, package-owned environment data).
    value = value
        .replaceAll(
          RegExp(
            r'(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;]+',
            caseSensitive: false,
          ),
          r'$1[REDACTED]',
        )
        .replaceAll(
          RegExp(
            r'''((?:api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|credential)\s*[:=]\s*)["']?[^\s,;"']+''',
            caseSensitive: false,
          ),
          r'$1[REDACTED]',
        )
        .replaceAll(RegExp(r'\bAIza[0-9A-Za-z_-]{20,}\b'), '[REDACTED]')
        .replaceAll(RegExp(r'\bsk-[A-Za-z0-9_-]{16,}\b'), '[REDACTED]');
    return value.length <= maxBytes
        ? value
        : value.substring(value.length - maxBytes);
  }
}

class WorkerProcessSpec {
  const WorkerProcessSpec({
    required this.workerId,
    required this.executable,
    this.protocolVersion = v7AdapterProtocolVersion,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.allowedEnvironmentVariables = const {},
    this.secretValues = const {},
    this.maxConcurrentAssignments = 1,
    this.includeParentEnvironment = true,
  });

  final String workerId;
  final String executable;
  final String protocolVersion;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final Set<String> allowedEnvironmentVariables;
  final Set<String> secretValues;
  final int maxConcurrentAssignments;
  final bool includeParentEnvironment;

  WorkerProcessSpec copyWith({
    String? workingDirectory,
    int? maxConcurrentAssignments,
    String? protocolVersion,
    Map<String, String>? environment,
    Set<String>? allowedEnvironmentVariables,
    bool? includeParentEnvironment,
  }) =>
      WorkerProcessSpec(
        workerId: workerId,
        executable: executable,
        protocolVersion: protocolVersion ?? this.protocolVersion,
        arguments: arguments,
        workingDirectory: workingDirectory ?? this.workingDirectory,
        environment: environment ?? this.environment,
        allowedEnvironmentVariables:
            allowedEnvironmentVariables ?? this.allowedEnvironmentVariables,
        secretValues: secretValues,
        maxConcurrentAssignments:
            maxConcurrentAssignments ?? this.maxConcurrentAssignments,
        includeParentEnvironment:
            includeParentEnvironment ?? this.includeParentEnvironment,
      );
}

class _QueuedWorkerExecution {
  _QueuedWorkerExecution(this.operationId);
  final String operationId;
  final Completer<void> permit = Completer<void>();
}

class _WorkerExecutionGate {
  _WorkerExecutionGate(this.limit);
  int limit;
  int active = 0;
  final Queue<_QueuedWorkerExecution> waiting = Queue();
}

class _SessionExecutionGate {
  bool active = false;
  final Queue<Completer<void>> waiting = Queue<Completer<void>>();
}

typedef WorkerProcessLauncher = Future<Process> Function(
    WorkerProcessSpec spec);
typedef WorkerProcessResolver = FutureOr<WorkerProcessSpec?> Function(
  String workerId,
);
typedef V7AdapterResolver = FutureOr<V7AdapterLaunch?> Function(
  String workerId, {
  String? expectedWorkerTypeId,
});
typedef WorkerProcessTerminator = Future<void> Function(
  Process process, {
  required bool force,
});
typedef WorkerNotificationHandler = FutureOr<void> Function(
  WorkerRpcNotification notification,
);
typedef V7AdapterProgressHandler = FutureOr<void> Function(
  String message,
  double? percentage,
);

class WorkerProcessExecutor {
  WorkerProcessExecutor({
    WorkerProcessLauncher? launcher,
    WorkerProcessTerminator? terminator,
    Map<String, String>? parentEnvironment,
    String? operatingSystem,
  })  : _launcher = launcher ??
            ((spec) => _launch(
                  spec,
                  parentEnvironment: parentEnvironment,
                  operatingSystem: operatingSystem,
                )),
        _terminator = terminator ?? terminateProcessTree;

  final WorkerProcessLauncher _launcher;
  final WorkerProcessTerminator _terminator;
  int _requestSequence = 0;
  int _operationSequence = 0;
  final _activeProcesses = <String, Process>{};
  final _v7ProcessCleanups = <String, Future<void>>{};
  final _activeResponses = <String, Completer<Map<String, Object?>>>{};
  final _cancelledOperations = <String>{};
  final _activeCancellations = <String, void Function()>{};
  final _workerGates = <String, _WorkerExecutionGate>{};
  final _sessionGates = <String, _SessionExecutionGate>{};
  final _queuedOperations = <String, _QueuedWorkerExecution>{};
  final _reservedOperations = <String>{};
  final _cancelledBeforeLaunch = <String>{};
  final _operationWorkers = <String, String>{};
  bool _shuttingDown = false;
  Future<void>? _shutdownFuture;

  static Future<Process> _launch(
    WorkerProcessSpec spec, {
    Map<String, String>? parentEnvironment,
    String? operatingSystem,
  }) {
    final executableName = spec.executable.split(Platform.pathSeparator).last;
    final arguments = executableName == 'dart' || executableName == 'dart.exe'
        ? ['--disable-analytics', ...spec.arguments]
        : spec.arguments;
    return startIsolatedProcess(
      spec.executable,
      arguments,
      workingDirectory: spec.workingDirectory,
      environment: safeWorkerEnvironment(
        spec.environment,
        allowedNames: spec.allowedEnvironmentVariables,
        parentEnvironment: parentEnvironment,
        operatingSystem: operatingSystem,
      ),
      includeParentEnvironment: spec.includeParentEnvironment,
    );
  }

  Future<Map<String, Object?>> execute(
    WorkerProcessSpec spec,
    Map<String, Object?> params, {
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
    String? operationId,
    WorkerNotificationHandler? onNotification,
  }) async {
    if (_shuttingDown) {
      throw StateError('Workspace is shutting down');
    }
    if (maxStdoutBytes <= 0 || maxStderrBytes <= 0) {
      throw ArgumentError('worker output limits must be positive');
    }
    if (spec.workerId.trim().isEmpty || spec.maxConcurrentAssignments < 1) {
      throw ArgumentError('Worker identity and concurrency limit are required');
    }
    final processId = operationId ??
        'host-operation-${DateTime.now().microsecondsSinceEpoch}-${++_operationSequence}';
    final elapsed = Stopwatch()..start();
    await _acquireWorkerSlot(
      spec.workerId,
      spec.maxConcurrentAssignments,
      processId,
      timeout,
    );
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      _releaseWorkerSlot(spec.workerId, processId);
      throw TimeoutException(
          'Worker assignment timed out before execution started', timeout);
    }
    try {
      return await _executeProcess(
        spec,
        params,
        timeout: remaining,
        maxStdoutBytes: maxStdoutBytes,
        maxStderrBytes: maxStderrBytes,
        operationId: processId,
        onNotification: onNotification,
      );
    } finally {
      _releaseWorkerSlot(spec.workerId, processId);
    }
  }

  /// Runs an admitted Architecture v7 adapter over strict newline-delimited
  /// JSON frames. It shares the local Worker gate and process-tree controls
  /// used by the existing Worker protocol executor.
  Future<Map<String, Object?>> executeV7Adapter(
    WorkerProcessSpec spec, {
    required String workerTypeId,
    required String adapterVersion,
    required String prompt,
    Map<String, Object?> config = const {},
    String? model,
    String sessionPolicy = 'stateless',
    String? sessionKey,
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 4 * 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
    String? operationId,
    V7AdapterProgressHandler? onProgress,
  }) async {
    if (_shuttingDown) {
      throw const V7AdapterExecutionFailure(
        code: 'cancelled',
        message: 'Workspace is shutting down.',
      );
    }
    if (maxStdoutBytes <= 0 || maxStderrBytes <= 0) {
      throw ArgumentError('adapter output limits must be positive');
    }
    if (!const {'stateless', 'durable_session'}.contains(sessionPolicy) ||
        (spec.protocolVersion == '2.5' &&
            ((sessionPolicy == 'durable_session') != (sessionKey != null) ||
                (sessionKey != null &&
                    (sessionKey.trim().isEmpty || sessionKey.length > 256)))) ||
        (sessionPolicy == 'durable_session' && spec.protocolVersion != '2.5') ||
        (sessionKey != null &&
            !const {'2.4', '2.5'}.contains(spec.protocolVersion))) {
      throw V7AdapterExecutionFailure(
        code: 'execution_failed',
        message: executionErrorMessage('execution_failed'),
      );
    }
    final processId = operationId ??
        'host-adapter-${DateTime.now().microsecondsSinceEpoch}-${++_operationSequence}';
    final elapsed = Stopwatch()..start();
    final sessionGateId = sessionPolicy == 'durable_session'
        ? '${spec.workerId}\u0000$sessionKey'
        : null;
    var sessionGateAcquired = false;
    var workerSlotAcquired = false;
    try {
      if (sessionGateId != null) {
        await _acquireSessionGate(sessionGateId, timeout);
        sessionGateAcquired = true;
      }
      final capacityWait = timeout - elapsed.elapsed;
      if (capacityWait <= Duration.zero) {
        throw TimeoutException(
          'Worker assignment timed out waiting for local capacity.',
          timeout,
        );
      }
      await _acquireWorkerSlot(
        spec.workerId,
        spec.maxConcurrentAssignments,
        processId,
        capacityWait,
      );
      workerSlotAcquired = true;
    } on TimeoutException {
      throw const V7AdapterExecutionFailure(
        code: 'timeout',
        message:
            'The assignment exceeded its time limit while waiting for local capacity.',
        retryable: true,
      );
    } finally {
      if (sessionGateAcquired && !workerSlotAcquired) {
        _releaseSessionGate(sessionGateId!);
      }
    }
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      _releaseWorkerSlot(spec.workerId, processId);
      if (sessionGateId != null) _releaseSessionGate(sessionGateId);
      throw const V7AdapterExecutionFailure(
        code: 'timeout',
        message:
            'The assignment exceeded its time limit before execution started.',
        retryable: true,
      );
    }
    try {
      return await _executeV7AdapterProcess(
        spec,
        workerTypeId: workerTypeId,
        adapterVersion: adapterVersion,
        prompt: prompt,
        config: config,
        model: model,
        sessionPolicy: sessionPolicy,
        sessionKey: sessionKey,
        timeout: remaining,
        maxStdoutBytes: maxStdoutBytes,
        maxStderrBytes: maxStderrBytes,
        operationId: processId,
        onProgress: onProgress,
      );
    } on TimeoutException {
      throw const V7AdapterExecutionFailure(
        code: 'timeout',
        message: 'The assignment exceeded its time limit.',
        retryable: true,
      );
    } finally {
      _releaseWorkerSlot(spec.workerId, processId);
      if (sessionGateId != null) _releaseSessionGate(sessionGateId);
    }
  }

  Future<Map<String, Object?>> _executeV7AdapterProcess(
    WorkerProcessSpec spec, {
    required String workerTypeId,
    required String adapterVersion,
    required String prompt,
    required Map<String, Object?> config,
    required String? model,
    required String sessionPolicy,
    required String? sessionKey,
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
    required String operationId,
    V7AdapterProgressHandler? onProgress,
  }) async {
    final elapsed = Stopwatch()..start();
    final process = await _launcher(spec);
    if (_cancelledBeforeLaunch.remove(operationId)) {
      await _terminateGracefully(process);
      throw const V7AdapterExecutionFailure(
        code: 'cancelled',
        message: 'The assignment was cancelled.',
      );
    }
    _activeProcesses[operationId] = process;
    var stdoutBytes = 0;
    var stderrBytes = 0;
    final stderrTail = _PackageStderrTail();
    final stderrDone = Completer<void>();
    final pending = <String, Completer<Map<String, Object?>>>{};
    var expectedAssignmentId = '';
    var expectedProgressRequestId = '';
    var failed = false;
    void fail(Object error) {
      if (failed) return;
      failed = true;
      for (final completer in pending.values) {
        if (!completer.isCompleted) completer.completeError(error);
      }
    }

    _activeCancellations[operationId] = () {
      fail(const V7AdapterExecutionFailure(
        code: 'cancelled',
        message: 'The assignment was cancelled.',
      ));
    };
    final stdoutSubscription = process.stdout
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            stdoutBytes += chunk.length;
            if (stdoutBytes > maxStdoutBytes) {
              fail(StateError('adapter stdout exceeded $maxStdoutBytes bytes'));
              sink.close();
            } else {
              sink.add(chunk);
            }
          },
        ))
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.trim().isEmpty || failed) return;
          try {
            final frame = parseV7AdapterFrame(line);
            if (frame['type'] == 'progress') {
              if (frame['assignmentId'] != expectedAssignmentId ||
                  frame['requestId'] != expectedProgressRequestId) {
                return;
              }
              final callback = onProgress;
              if (callback != null) {
                unawaited(Future.sync(() => callback(
                      redactSecrets(
                        frame['message']! as String,
                        spec.secretValues,
                      ),
                      (frame['percentage'] as num?)?.toDouble(),
                    )).catchError((_) {}));
              }
              return;
            }
            final requestId = frame['requestId'];
            if (requestId is String) {
              final completer = pending[requestId];
              if (completer != null && !completer.isCompleted) {
                completer.complete(frame);
              }
            }
          } on Object catch (error) {
            fail(error);
          }
        });
    final stderrSubscription = process.stderr.listen((chunk) {
      stderrBytes += chunk.length;
      stderrTail.add(chunk);
      if (stderrBytes > maxStderrBytes) {
        fail(V7AdapterExecutionFailure(
          code: 'execution_failed',
          message: 'The local adapter exceeded its diagnostic output limit.',
          localDiagnostic: stderrTail.readRedacted(spec.secretValues),
        ));
      }
    }, onDone: () {
      if (!stderrDone.isCompleted) stderrDone.complete();
    });
    unawaited(process.exitCode.then((code) async {
      await stderrDone.future;
      if (!failed && pending.values.any((item) => !item.isCompleted)) {
        fail(V7AdapterExecutionFailure(
          code: 'execution_failed',
          message: 'The local adapter stopped before completing the request.',
          localDiagnostic: stderrTail.readRedacted(spec.secretValues),
        ));
      }
    }));
    Future<Map<String, Object?>> request(
      String type,
      String responseType,
      Map<String, Object?> fields,
    ) async {
      if (failed) throw StateError('adapter process has failed');
      final requestId =
          'host-${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
      final completer = Completer<Map<String, Object?>>();
      pending[requestId] = completer;
      process.stdin.writeln(serializeV7AdapterFrame({
        'type': type,
        'protocolVersion': spec.protocolVersion,
        'requestId': requestId,
        ...fields,
      }));
      await process.stdin.flush();
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        fail(TimeoutException('adapter $type timed out', timeout));
        throw TimeoutException('adapter $type timed out', timeout);
      }
      final frame = await completer.future.timeout(remaining, onTimeout: () {
        fail(TimeoutException('adapter $type timed out', timeout));
        throw TimeoutException('adapter $type timed out', timeout);
      });
      pending.remove(requestId);
      if (frame['type'] == 'error') {
        final code = canonicalExecutionErrorCode(frame['code']);
        throw V7AdapterExecutionFailure(
          code: code,
          message: executionErrorMessage(code),
          retryable: frame['retryable'] == true,
        );
      }
      if (frame['type'] != responseType) {
        throw StateError('adapter returned ${frame['type']} for $type');
      }
      return frame;
    }

    try {
      final initialize =
          await request('initialize.request', 'initialize.result', {
        'workerTypeId': workerTypeId,
        'adapterVersion': adapterVersion,
      });
      if (initialize['adapterVersion'] != adapterVersion) {
        throw StateError('adapter initialize version mismatch');
      }
      final probe = await request('probe.request', 'probe.result', {
        if (const {'2.3', '2.4', '2.5'}.contains(spec.protocolVersion))
          'mode': 'passive',
        'config': _safeAdapterProbeConfig(config),
      });
      if (probe['ready'] != true) {
        final checks = probe['checks'] as List? ?? const [];
        final issues = probe['issues'] as List? ?? const [];
        final issueCode = [
          ...checks
              .whereType<Map>()
              .where((check) => check['status'] == 'failed'),
          ...issues.whereType<Map>(),
        ]
            .map((issue) => issue['issueCode'] ?? issue['code'])
            .whereType<String>()
            .firstWhere(
              (value) => const {
                'worker_not_ready',
                'authentication_required',
                'permission_denied',
                'permission_configuration_required',
                'execution_test_failed',
                'model_not_supported',
                'quota_exhausted',
                'provider_unavailable',
                'timeout',
                'cancelled',
                'internal_adapter_error',
                'execution_failed',
              }.contains(value),
              orElse: () => 'internal_adapter_error',
            );
        final code = canonicalExecutionErrorCode(switch (issueCode) {
          'permission_configuration_required' => 'permission_denied',
          'execution_test_failed' => 'execution_failed',
          _ => issueCode,
        });
        throw V7AdapterExecutionFailure(
          code: code,
          message: executionErrorMessage(code),
        );
      }
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        const failure = V7AdapterExecutionFailure(
          code: 'timeout',
          message: 'The assignment exceeded its time limit.',
          retryable: true,
        );
        fail(failure);
        throw failure;
      }
      expectedAssignmentId = operationId;
      final executeId =
          'host-${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
      expectedProgressRequestId = executeId;
      final executeResponse = Completer<Map<String, Object?>>();
      pending[executeId] = executeResponse;
      process.stdin.writeln(serializeV7AdapterFrame({
        'type': 'execute.request',
        'protocolVersion': spec.protocolVersion,
        'requestId': executeId,
        'assignmentId': operationId,
        'prompt': prompt,
        if (model != null && model.isNotEmpty) 'model': model,
        if (spec.protocolVersion == '2.5') 'sessionPolicy': sessionPolicy,
        if (sessionKey != null) 'sessionKey': sessionKey,
        if (const {'2.4', '2.5'}.contains(spec.protocolVersion))
          'timeoutMs': max(1, remaining.inMilliseconds),
      }));
      await process.stdin.flush();
      final responseRemaining = timeout - elapsed.elapsed;
      if (responseRemaining <= Duration.zero) {
        const failure = V7AdapterExecutionFailure(
          code: 'timeout',
          message: 'The assignment exceeded its time limit.',
          retryable: true,
        );
        fail(failure);
        throw failure;
      }
      final result = await executeResponse.future.timeout(responseRemaining,
          onTimeout: () {
        const failure = V7AdapterExecutionFailure(
          code: 'timeout',
          message: 'The assignment exceeded its time limit.',
          retryable: true,
        );
        fail(failure);
        throw failure;
      });
      if (result['type'] == 'error') {
        final code = canonicalExecutionErrorCode(result['code']);
        throw V7AdapterExecutionFailure(
          code: code,
          message: executionErrorMessage(code),
          retryable: result['retryable'] == true,
        );
      }
      if (result['type'] != 'result' || result['assignmentId'] != operationId) {
        throw StateError('adapter terminal result correlation is invalid');
      }
      final output =
          redactSecrets(result['output']! as String, spec.secretValues);
      return {
        'summary': output.split('\n').first,
        'output': {
          'text': output,
          'artifacts': _redactValue(
            result['artifacts'] ?? const [],
            spec.secretValues,
          )
        },
        'artifactIds': const <String>[],
      };
    } finally {
      await process.stdin.close();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      await _terminateV7Process(operationId, process);
      _v7ProcessCleanups.remove(operationId);
      _activeProcesses.remove(operationId);
      _activeCancellations.remove(operationId);
      _cancelledOperations.remove(operationId);
    }
  }

  /// Starts one Worker Package, initializes it, and requests its readiness
  /// probe. A caller may request the package's live test; Workspace sends only
  /// the generic mode while commands, prompts, and interpretation remain in
  /// the package.
  Future<Map<String, Object?>> checkV7AdapterHealth(
    WorkerProcessSpec spec, {
    required String workerTypeId,
    required String adapterVersion,
    required String healthCheckMode,
    Duration timeout = const Duration(seconds: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 256 * 1024,
    bool allowNotReady = false,
    LocalWorkerProbeMode mode = LocalWorkerProbeMode.passive,
  }) async {
    if (healthCheckMode != 'protocol' ||
        timeout <= Duration.zero ||
        maxStdoutBytes <= 0 ||
        maxStderrBytes <= 0) {
      throw ArgumentError('Worker Package health-check policy is invalid');
    }
    final process = await _launcher(spec);
    final elapsed = Stopwatch()..start();
    var stdoutBytes = 0;
    var stderrBytes = 0;
    final stderrTail = _PackageStderrTail();
    final stderrDone = Completer<void>();
    var failed = false;
    Completer<Map<String, Object?>>? pending;
    String? expectedRequestId;
    String? expectedResponseType;

    void fail(Object error) {
      if (failed) return;
      failed = true;
      if (pending != null && !pending!.isCompleted) {
        pending!.completeError(error);
      }
      unawaited(_terminator(process, force: true));
    }

    final stderrSubscription = process.stderr.listen((chunk) {
      stderrBytes += chunk.length;
      stderrTail.add(chunk);
      if (stderrBytes > maxStderrBytes) {
        fail(V7AdapterExecutionFailure(
          code: 'execution_failed',
          message: 'The Worker Package exceeded its diagnostic output limit.',
          localDiagnostic: stderrTail.readRedacted(spec.secretValues),
        ));
      }
    }, onDone: () {
      if (!stderrDone.isCompleted) stderrDone.complete();
    });
    final lineSubscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (failed || line.trim().isEmpty) return;
      stdoutBytes += utf8.encode(line).length + 1;
      if (stdoutBytes > maxStdoutBytes) {
        fail(StateError('Worker Package health output exceeded its limit'));
        return;
      }
      try {
        final frame = parseV7AdapterFrame(line);
        if (frame['requestId'] != expectedRequestId ||
            (frame['type'] != expectedResponseType &&
                frame['type'] != 'error')) {
          throw StateError('Worker Package returned an unexpected response');
        }
        if (pending != null && !pending!.isCompleted) {
          pending!.complete(frame);
        }
      } on Object catch (error) {
        fail(error);
      }
    }, onError: fail);
    unawaited(process.exitCode.then((code) async {
      await stderrDone.future;
      if (!failed && pending != null && !pending!.isCompleted) {
        fail(V7AdapterExecutionFailure(
          code: 'execution_failed',
          message: 'The Worker Package exited before returning its probe.',
          localDiagnostic: stderrTail.readRedacted(spec.secretValues),
        ));
      }
    }));

    Future<Map<String, Object?>> request(
      String type,
      String responseType,
      Map<String, Object?> fields,
    ) async {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
            'Worker Package health check timed out', timeout);
      }
      final requestId =
          'health-${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
      expectedRequestId = requestId;
      expectedResponseType = responseType;
      final response = Completer<Map<String, Object?>>();
      pending = response;
      process.stdin.writeln(serializeV7AdapterFrame({
        'type': type,
        'protocolVersion': spec.protocolVersion,
        'requestId': requestId,
        ...fields,
      }));
      await process.stdin.flush();
      final frame = await response.future.timeout(remaining, onTimeout: () {
        fail(TimeoutException('Worker Package $type timed out', remaining));
        throw TimeoutException('Worker Package $type timed out', remaining);
      });
      pending = null;
      if (frame['type'] == 'error') {
        throw StateError('Worker Package rejected $type');
      }
      return frame;
    }

    try {
      final initialized =
          await request('initialize.request', 'initialize.result', {
        'workerTypeId': workerTypeId,
        'adapterVersion': adapterVersion,
      });
      if (initialized['adapterVersion'] != adapterVersion) {
        throw StateError('Worker Package initialize version mismatch');
      }
      final supportsProbeMode =
          const {'2.2', '2.3', '2.4', '2.5'}.contains(spec.protocolVersion);
      if (!supportsProbeMode && mode == LocalWorkerProbeMode.live) {
        throw StateError(
            'This Worker Package protocol does not support live probes');
      }
      final config = spec.protocolVersion == '2.2'
          ? {'mode': mode.wireValue}
          : const <String, Object?>{};
      final probe = await request('probe.request', 'probe.result', {
        if (const {'2.3', '2.4', '2.5'}.contains(spec.protocolVersion))
          'mode': mode.wireValue,
        if (config.isNotEmpty) 'config': config,
      });
      final probeContractValid =
          const {'2.3', '2.4', '2.5'}.contains(spec.protocolVersion)
              ? probe['mode'] == mode.wireValue && probe['checks'] is List
              : probe['checkKind'] == 'readiness';
      if (!probeContractValid || (probe['ready'] != true && !allowNotReady)) {
        throw StateError('Worker Package ${mode.wireValue} probe failed');
      }
      return probe;
    } finally {
      await process.stdin.close();
      await lineSubscription.cancel();
      await stderrSubscription.cancel();
      await _terminateGracefully(process);
    }
  }

  Future<Map<String, Object?>> _executeProcess(
    WorkerProcessSpec spec,
    Map<String, Object?> params, {
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
    required String operationId,
    WorkerNotificationHandler? onNotification,
  }) async {
    final process = await _launcher(spec);
    final requestId = 'host-${DateTime.now().microsecondsSinceEpoch}-'
        '${++_requestSequence}';
    final processId = operationId;
    if (_cancelledBeforeLaunch.remove(processId)) {
      await _terminateGracefully(process);
      throw ProcessException(
        'cancelled',
        const [],
        'Worker assignment cancelled before launch completed',
      );
    }
    _activeProcesses[processId] = process;
    final pending = <String, Completer<Map<String, Object?>>>{};
    final response = Completer<Map<String, Object?>>();
    _activeResponses[processId] = response;
    _activeCancellations[processId] = () {
      for (final pendingResponse in pending.values) {
        if (!pendingResponse.isCompleted) {
          pendingResponse.completeError(
            ProcessException(
              'cancelled',
              const [],
              'Worker assignment cancelled',
            ),
          );
        }
      }
    };
    var stdoutBytes = 0;
    var stderrBytes = 0;
    final stderrPreview = StringBuffer();
    void fail(String message) {
      for (final pendingResponse in pending.values) {
        if (!pendingResponse.isCompleted) {
          pendingResponse.completeError(StateError(message));
        }
      }
      unawaited(_terminator(process, force: true));
    }

    final boundedStdout = process.stdout.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          stdoutBytes += chunk.length;
          if (stdoutBytes > maxStdoutBytes) {
            fail('worker stdout exceeded $maxStdoutBytes bytes');
            sink.close();
            return;
          }
          sink.add(chunk);
        },
      ),
    );
    final stdoutSubscription = boundedStdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) async {
      if (response.isCompleted || line.trim().isEmpty) return;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map<String, dynamic> && decoded['id'] == null) {
          final notification = WorkerRpcNotification.parse(decoded);
          if (onNotification != null) {
            try {
              await onNotification(notification);
            } catch (_) {
              // Realtime delivery is best effort and must never interrupt the
              // Worker execution or suppress its terminal response.
            }
          }
          return;
        }
        final rpc = WorkerRpcResponse.parse(decoded);
        final pendingResponse = pending[rpc.id];
        if (pendingResponse == null || pendingResponse.isCompleted) return;
        if (rpc.error != null) {
          pendingResponse.completeError(StateError(
              '${rpc.error!['message'] ?? 'worker request failed'}'));
          return;
        }
        pendingResponse.complete(rpc.result!);
      } on Object catch (error) {
        // `dart run` may emit its VM service banner on stdout before the
        // worker starts. It is launcher noise, not a worker protocol frame.
        if (line.startsWith('The Dart VM service is listening on ')) return;
        for (final pendingResponse in pending.values) {
          if (!pendingResponse.isCompleted) {
            pendingResponse.completeError(error);
          }
        }
      }
    });
    final stderrSubscription = process.stderr.listen((chunk) {
      stderrBytes += chunk.length;
      if (stderrPreview.length < 4096) {
        stderrPreview.write(utf8.decode(chunk, allowMalformed: true));
      }
      if (stderrBytes > maxStderrBytes) {
        fail('worker stderr exceeded $maxStderrBytes bytes');
      }
    });
    unawaited(process.exitCode.then((exitCode) {
      if (!_cancelledOperations.contains(processId) &&
          pending.values
              .any((pendingResponse) => !pendingResponse.isCompleted)) {
        fail('worker process exited with code $exitCode before completing');
      }
    }));
    Future<Map<String, Object?>> request(
      String method,
      Map<String, Object?> params,
    ) async {
      final id = method == 'execute' ? requestId : '$requestId-$method';
      final pendingResponse =
          method == 'execute' ? response : Completer<Map<String, Object?>>();
      pending[id] = pendingResponse;
      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }));
      await process.stdin.flush();
      return pendingResponse.future;
    }

    try {
      final execution = () async {
        final initialized = await request('initialize', {
          'workerId': spec.workerId,
          'protocolVersion': workerProtocolVersion,
        });
        final identity = WorkerIdentity.parse(initialized);
        if (identity.workerId != spec.workerId ||
            identity.protocolVersion != workerProtocolVersion) {
          throw StateError('worker handshake identity is invalid');
        }
        final health = await request('health', {});
        if (health['status'] != 'healthy') {
          throw StateError('worker health check failed');
        }
        return await request('execute', params);
      }();
      final result = await execution.timeout(
        timeout,
        onTimeout: () {
          fail('worker execution timed out after $timeout');
          throw TimeoutException(
            'worker execution timed out; stderr: ${redactSecrets(stderrPreview.toString(), spec.secretValues)}',
            timeout,
          );
        },
      );
      final redacted = _redactValue(result, spec.secretValues);
      return Map<String, Object?>.from(redacted as Map);
    } finally {
      await process.stdin.close();
      await stdoutSubscription.cancel();
      await stderrSubscription.cancel();
      await _terminateGracefully(process);
      _activeProcesses.remove(processId);
      _activeResponses.remove(processId);
      _cancelledOperations.remove(processId);
      _activeCancellations.remove(processId);
    }
  }

  Future<bool> cancel(String operationId) async {
    final process = _activeProcesses[operationId];
    if (process == null) {
      final queued = _queuedOperations.remove(operationId);
      if (queued != null) {
        _operationWorkers.remove(operationId);
        _WorkerExecutionGate? owningGate;
        for (final gate in _workerGates.values) {
          if (gate.waiting.remove(queued)) {
            owningGate = gate;
            break;
          }
        }
        if (owningGate != null && !queued.permit.isCompleted) {
          queued.permit.completeError(ProcessException(
            'cancelled',
            const [],
            'Worker assignment cancelled while waiting for local capacity',
          ));
        }
        return true;
      }
      if (_reservedOperations.contains(operationId)) {
        _cancelledBeforeLaunch.add(operationId);
        return true;
      }
      return false;
    }
    _activeProcesses.remove(operationId);
    _cancelledOperations.add(operationId);
    _activeCancellations.remove(operationId)?.call();
    await _terminateV7Process(operationId, process);
    return true;
  }

  /// Stops accepting work and terminates every active, starting, and queued
  /// process tree. A reserved operation cancelled during launch observes the
  /// pre-launch cancellation marker immediately after its process is created.
  Future<void> shutdown() => _shutdownFuture ??= _performShutdown();

  Future<void> _performShutdown() async {
    _shuttingDown = true;
    final operations = _operationWorkers.keys.toList(growable: false);
    for (final operationId in operations) {
      await cancel(operationId);
    }
    // Cancellation may have raced a process launch. Wait until each operation
    // has observed cancellation and completed its process cleanup path.
    while (_operationWorkers.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final operationId
          in _operationWorkers.keys.toList(growable: false)) {
        if (_activeProcesses.containsKey(operationId)) {
          await cancel(operationId);
        } else if (_reservedOperations.contains(operationId) ||
            _queuedOperations.containsKey(operationId)) {
          await cancel(operationId);
        }
      }
    }
  }

  /// Cancels every active, starting, or locally queued operation owned by a
  /// Worker before Workspace removes that Worker and its credentials.
  Future<int> cancelWorker(String workerId) async {
    final operations = _operationWorkers.entries
        .where((entry) => entry.value == workerId)
        .map((entry) => entry.key)
        .toList(growable: false);
    var cancelled = 0;
    for (final operationId in operations) {
      if (await cancel(operationId)) cancelled++;
    }
    return cancelled;
  }

  Future<void> _acquireWorkerSlot(
    String workerId,
    int requestedLimit,
    String operationId,
    Duration timeout,
  ) async {
    if (_shuttingDown) {
      throw StateError('Workspace is shutting down');
    }
    if (_activeProcesses.containsKey(operationId) ||
        _queuedOperations.containsKey(operationId) ||
        _reservedOperations.contains(operationId)) {
      throw StateError('operation ID is already active: $operationId');
    }
    _operationWorkers[operationId] = workerId;
    final gate = _workerGates.putIfAbsent(
      workerId,
      () => _WorkerExecutionGate(requestedLimit),
    );
    gate.limit = min(gate.limit, requestedLimit);
    if (gate.active < gate.limit) {
      gate.active++;
      _reservedOperations.add(operationId);
      return;
    }
    final queued = _QueuedWorkerExecution(operationId);
    gate.waiting.addLast(queued);
    _queuedOperations[operationId] = queued;
    try {
      await queued.permit.future.timeout(
        timeout,
        onTimeout: () {
          if (gate.waiting.remove(queued)) {
            _queuedOperations.remove(operationId);
            _operationWorkers.remove(operationId);
            if (gate.active == 0 && gate.waiting.isEmpty) {
              _workerGates.remove(workerId);
            }
          }
          throw TimeoutException(
            'Worker assignment timed out waiting for local concurrency capacity',
            timeout,
          );
        },
      );
      if (_shuttingDown || _cancelledBeforeLaunch.contains(operationId)) {
        throw StateError('Worker assignment was cancelled before launch');
      }
    } finally {
      _queuedOperations.remove(operationId);
    }
  }

  Future<void> _acquireSessionGate(String sessionId, Duration timeout) async {
    if (_shuttingDown) {
      throw StateError('Workspace is shutting down');
    }
    final gate = _sessionGates.putIfAbsent(
      sessionId,
      _SessionExecutionGate.new,
    );
    if (!gate.active) {
      gate.active = true;
      return;
    }
    final queued = Completer<void>();
    gate.waiting.addLast(queued);
    await queued.future.timeout(
      timeout,
      onTimeout: () {
        gate.waiting.remove(queued);
        throw TimeoutException(
          'Worker assignment timed out waiting for its durable session.',
          timeout,
        );
      },
    );
    if (_shuttingDown) {
      _releaseSessionGate(sessionId);
      throw StateError('Workspace is shutting down');
    }
  }

  void _releaseSessionGate(String sessionId) {
    final gate = _sessionGates[sessionId];
    if (gate == null) return;
    while (gate.waiting.isNotEmpty) {
      final next = gate.waiting.removeFirst();
      if (next.isCompleted) continue;
      next.complete();
      return;
    }
    gate.active = false;
    _sessionGates.remove(sessionId);
  }

  void _releaseWorkerSlot(String workerId, String operationId) {
    _operationWorkers.remove(operationId);
    _reservedOperations.remove(operationId);
    _cancelledBeforeLaunch.remove(operationId);
    final gate = _workerGates[workerId];
    if (gate == null) return;
    gate.active--;
    while (gate.active < gate.limit && gate.waiting.isNotEmpty) {
      final next = gate.waiting.removeFirst();
      _queuedOperations.remove(next.operationId);
      if (next.permit.isCompleted) continue;
      gate.active++;
      _reservedOperations.add(next.operationId);
      next.permit.complete();
    }
    if (gate.active == 0 && gate.waiting.isEmpty) {
      _workerGates.remove(workerId);
    }
  }

  Future<void> _terminateGracefully(Process process) async {
    await _terminator(process, force: false);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // The tree kill below also handles descendants that outlive the parent.
    }
    await _terminator(process, force: true);
  }

  Future<void> _terminateV7Process(String operationId, Process process) =>
      _v7ProcessCleanups.putIfAbsent(
        operationId,
        () => _terminateGracefully(process),
      );
}

class V7AdapterLaunch {
  const V7AdapterLaunch({
    required this.processSpec,
    required this.workerTypeId,
    required this.adapterVersion,
    this.config = const {},
    this.defaultModel,
    this.allowedModels = const {},
  });

  final WorkerProcessSpec processSpec;
  final String workerTypeId;
  final String adapterVersion;
  final Map<String, Object?> config;
  final String? defaultModel;
  final Set<String> allowedModels;

  V7AdapterLaunch copyWith({WorkerProcessSpec? processSpec}) => V7AdapterLaunch(
        processSpec: processSpec ?? this.processSpec,
        workerTypeId: workerTypeId,
        adapterVersion: adapterVersion,
        config: config,
        defaultModel: defaultModel,
        allowedModels: allowedModels,
      );
}

Map<String, String> safeWorkerEnvironment(
  Map<String, String> requested, {
  Set<String> allowedNames = const {},
  Map<String, String>? parentEnvironment,
  String? operatingSystem,
}) {
  final environment = <String, String>{};
  final parent = parentEnvironment ?? Platform.environment;
  final os = operatingSystem ?? Platform.operatingSystem;
  const maxEntries = 128;
  const maxValueBytes = 64 * 1024;
  const maxTotalBytes = 256 * 1024;
  var totalBytes = 0;
  void add(String name, String value) {
    if (value.isEmpty) return;
    final valueBytes = utf8.encode(value).length;
    if (valueBytes > maxValueBytes ||
        (!environment.containsKey(name) && environment.length >= maxEntries) ||
        totalBytes + name.length + valueBytes > maxTotalBytes) {
      throw StateError('Worker environment exceeds its configured bounds');
    }
    if (environment.containsKey(name)) {
      totalBytes -= name.length + utf8.encode(environment[name]!).length;
    }
    environment[name] = value;
    totalBytes += name.length + valueBytes;
  }

  for (final name in const [
    'HOME',
    'USERPROFILE',
    'TMPDIR',
    'TMP',
    'TEMP',
    'SystemRoot',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    // TLS certificate configuration for provider connections.
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
    // Disable colour output and interactive prompts in headless workers.
    'NO_COLOR',
    'TERM',
  ]) {
    final value = parent[name];
    if (value != null) add(name, value);
  }
  final path = _workerLaunchPath(
    parentPath: parent['PATH'],
    homeDirectory: parent['HOME'] ?? parent['USERPROFILE'],
    systemRoot: parent['SystemRoot'],
    operatingSystem: os,
  );
  if (path.isNotEmpty) add('PATH', path);
  for (final name in allowedNames) {
    // PATH is a centrally constructed runtime baseline, never a package
    // passthrough value. In particular, admission must not replace the
    // GUI-safe path with the unfiltered parent value.
    if (name == 'PATH') continue;
    final value = parent[name];
    if (value != null) add(name, value);
  }
  // Worker processes are non-interactive. Prevent language runtimes from
  // blocking on first-run telemetry prompts while the Host is executing.
  add('DART_SUPPRESS_ANALYTICS', '1');
  for (final entry in requested.entries) {
    if (allowedNames.contains(entry.key)) add(entry.key, entry.value);
  }
  return environment;
}

String _workerLaunchPath({
  required String? parentPath,
  required String? homeDirectory,
  required String? systemRoot,
  required String operatingSystem,
}) {
  final isWindows = operatingSystem == 'windows';
  final separator = isWindows ? ';' : ':';
  final defaults = <String>[];
  if (isWindows) {
    final root = systemRoot;
    if (root != null && root.isNotEmpty) {
      defaults.addAll([
        '$root\\System32',
        root,
        '$root\\System32\\Wbem',
        '$root\\System32\\WindowsPowerShell\\v1.0',
      ]);
    }
  } else if (operatingSystem == 'macos') {
    defaults.addAll(const [
      '/opt/homebrew/bin',
      '/opt/homebrew/sbin',
      '/usr/local/bin',
      '/usr/local/sbin',
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
    ]);
  } else {
    defaults.addAll(const [
      '/usr/local/bin',
      '/usr/local/sbin',
      '/usr/bin',
      '/usr/sbin',
      '/bin',
      '/sbin',
    ]);
  }
  if (!isWindows && homeDirectory != null && homeDirectory.isNotEmpty) {
    defaults.addAll([
      '$homeDirectory/.local/bin',
      '$homeDirectory/bin',
    ]);
  }

  final paths = <String>[];
  final seen = <String>{};
  for (final candidate in [
    ...(parentPath ?? '').split(separator),
    ...defaults,
  ]) {
    final path = candidate.trim();
    if (path.isEmpty || !_isAbsoluteWorkerPath(path, isWindows)) continue;
    final key = isWindows ? path.toLowerCase() : path;
    if (seen.add(key)) paths.add(path);
  }
  return paths.join(separator);
}

bool _isAbsoluteWorkerPath(String path, bool isWindows) => isWindows
    ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) || path.startsWith(r'\\')
    : path.startsWith('/');

class WorkerAssignmentHandler {
  const WorkerAssignmentHandler({
    required this.executor,
    required this.resolve,
    this.resolveV7Adapter,
    this.resolveRepositoryPath,
    this.resolvePermissions,
    this.resolveConcurrencyLimit,
    this.workstreamDirectoryLifecycle,
    this.workstreamMutationCoordinator,
    this.onNotification,
  });

  final WorkerProcessExecutor executor;
  final WorkerProcessResolver resolve;
  final V7AdapterResolver? resolveV7Adapter;
  final Future<String?> Function(String repositoryId)? resolveRepositoryPath;
  final Future<Set<String>> Function(String workerId)? resolvePermissions;
  final Future<int?> Function(String workerId)? resolveConcurrencyLimit;
  final WorkstreamDirectoryLifecycle? workstreamDirectoryLifecycle;
  final WorkstreamMutationCoordinator? workstreamMutationCoordinator;
  final WorkerNotificationRelay? onNotification;

  /// Resolves the local process specification for an assignment.
  ///
  /// When Project/Workstream identity is present, the returned CWD is always
  /// resolved locally from those IDs. Cloud-supplied CWD fields are rejected.
  Future<WorkerProcessSpec> prepareProcessSpec(
      HostAssignmentContext context) async {
    return (await _prepareResolvedProcessSpec(context)).$1;
  }

  Future<(WorkerProcessSpec, V7AdapterLaunch?)> _prepareResolvedProcessSpec(
      HostAssignmentContext context) async {
    final workerId = context.payload['workerId'];
    if (workerId is! String || workerId.isEmpty) {
      throw StateError('assignment workerId is required');
    }
    final expectedWorkerTypeId = context.payload['workerTypeId'];
    final v7Adapter = await resolveV7Adapter?.call(
      workerId,
      expectedWorkerTypeId:
          expectedWorkerTypeId is String ? expectedWorkerTypeId : null,
    );
    final spec = v7Adapter?.processSpec ?? await resolve(workerId);
    if (spec == null) throw StateError('worker is not installed: $workerId');
    rejectWorkerControlledPaths(context.payload);
    final executionClass = context.payload['executionClass'];
    final projectId = _requiredStringForWorkstream(
        context.payload['projectId'], 'projectId', executionClass);
    final workstreamId = _requiredStringForWorkstream(
        context.payload['workstreamId'], 'workstreamId', executionClass);
    final localConcurrency = await resolveConcurrencyLimit?.call(workerId);
    if (localConcurrency != null && localConcurrency < 1) {
      throw StateError('local Worker concurrency limit must be positive');
    }
    var runtimeSpec = localConcurrency == null
        ? spec
        : spec.copyWith(maxConcurrentAssignments: localConcurrency);
    if (projectId != null && workstreamId != null) {
      final lifecycle = workstreamDirectoryLifecycle;
      if (lifecycle == null) {
        throw const RuntimeViolation(
            'Workstream directory lifecycle is required for scoped execution');
      }
      final directory = await lifecycle.ensureForExecution(
        projectId: projectId,
        workstreamId: workstreamId,
      );
      runtimeSpec = runtimeSpec.copyWith(workingDirectory: directory.path);
    }
    return (runtimeSpec, v7Adapter);
  }

  Future<HostAssignmentResult> call(HostAssignmentContext context) async {
    final workerId = context.payload['workerId'];
    if (workerId is! String || workerId.isEmpty) {
      throw StateError('assignment workerId is required');
    }
    final (runtimeSpec, v7Adapter) = await _prepareResolvedProcessSpec(context);
    final allowed =
        await resolvePermissions?.call(workerId) ?? const <String>{};
    if (context.payload['permissionSnapshot'] != null) {
      validateAssignmentScope(
        context.payload,
        manifestPermissions: allowed,
      );
    }
    final requestedPermissions = context.payload['permissions'];
    if (requestedPermissions != null) {
      if (requestedPermissions is! List ||
          requestedPermissions.any((item) => item is! String)) {
        throw V7AdapterExecutionFailure(
          code: 'permission_denied',
          message: executionErrorMessage('permission_denied'),
        );
      }
      final denied = requestedPermissions.whereType<String>().firstWhere(
          (permission) => !runtimePermissionAllowed(permission, allowed),
          orElse: () => '');
      if (denied.isNotEmpty) {
        throw V7AdapterExecutionFailure(
          code: 'permission_denied',
          message: executionErrorMessage('permission_denied'),
        );
      }
    }
    Future<HostAssignmentResult> execute() async {
      final workerPayload =
          await _repositoryScopedPayload(context.payload, context);
      final output = v7Adapter == null
          ? await executor.execute(
              runtimeSpec,
              workerPayload,
              operationId: context.assignmentId,
              onNotification: onNotification == null
                  ? null
                  : (notification) => onNotification!(
                        context,
                        _redactNotification(
                            notification, runtimeSpec.secretValues),
                      ),
            )
          : await executor.executeV7Adapter(
              runtimeSpec,
              workerTypeId: v7Adapter.workerTypeId,
              adapterVersion: v7Adapter.adapterVersion,
              prompt: _v7Prompt(workerPayload),
              config: v7Adapter.config,
              model: _resolveV7Model(workerPayload, v7Adapter),
              sessionPolicy: _v7SessionPolicy(workerPayload),
              timeout: Duration(
                milliseconds: context.payload['timeoutMs'] as int,
              ),
              sessionKey: _v7SessionKey(workerPayload),
              operationId: context.assignmentId,
              onProgress: onNotification == null
                  ? null
                  : (message, percentage) => onNotification!(
                        context,
                        WorkerRpcNotification(
                          method: 'worker.progress',
                          params: {
                            'message': message,
                            if (percentage != null) 'percentage': percentage,
                          },
                        ),
                      ),
            );
      final summary = output['summary'];
      final nestedOutput = output['output'];
      return HostAssignmentResult(
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

  String _v7Prompt(Map<String, Object?> payload) {
    final input = payload['input'];
    if (input is Map && input['prompt'] is String) {
      return input['prompt'] as String;
    }
    if (payload['prompt'] is String) return payload['prompt'] as String;
    final promptPayload = Map<String, Object?>.from(payload)
      ..remove('sessionKey');
    promptPayload.remove('sessionPolicy');
    final promptInput = promptPayload['input'];
    if (promptInput is Map) {
      promptPayload['input'] = Map<String, Object?>.from(promptInput)
        ..remove('sessionKey')
        ..remove('sessionPolicy');
    }
    return jsonEncode(promptPayload);
  }

  String? _v7SessionKey(Map<String, Object?> payload) {
    final input = payload['input'];
    final value =
        payload['sessionKey'] ?? (input is Map ? input['sessionKey'] : null);
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty || value.length > 256) {
      throw V7AdapterExecutionFailure(
        code: 'execution_failed',
        message: executionErrorMessage('execution_failed'),
      );
    }
    return value.trim();
  }

  String _v7SessionPolicy(Map<String, Object?> payload) {
    final input = payload['input'];
    final value = payload['sessionPolicy'] ??
        (input is Map ? input['sessionPolicy'] : null) ??
        'stateless';
    if (!const {'stateless', 'durable_session'}.contains(value)) {
      throw V7AdapterExecutionFailure(
        code: 'execution_failed',
        message: executionErrorMessage('execution_failed'),
      );
    }
    return value as String;
  }

  String? _v7Model(Map<String, Object?> payload) {
    final model = payload['model'];
    if (model is String && model.trim().isNotEmpty) return model.trim();
    final input = payload['input'];
    if (input is Map && input['model'] is String) {
      final nested = (input['model'] as String).trim();
      if (nested.isNotEmpty) return nested;
    }
    return null;
  }

  String? _resolveV7Model(
    Map<String, Object?> payload,
    V7AdapterLaunch adapter,
  ) {
    final requested = _v7Model(payload);
    if (requested != null &&
        adapter.allowedModels.isNotEmpty &&
        !adapter.allowedModels.contains(requested)) {
      throw V7AdapterExecutionFailure(
        code: 'model_not_supported',
        message: executionErrorMessage('model_not_supported'),
      );
    }
    final selected = requested ?? adapter.defaultModel;
    if (selected != null &&
        adapter.allowedModels.isNotEmpty &&
        !adapter.allowedModels.contains(selected)) {
      throw V7AdapterExecutionFailure(
        code: 'model_not_supported',
        message: executionErrorMessage('model_not_supported'),
      );
    }
    return selected;
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

  WorkerRpcNotification _redactNotification(
    WorkerRpcNotification notification,
    Set<String> secrets,
  ) =>
      WorkerRpcNotification(
        method: notification.method,
        params: Map<String, Object?>.from(
          _redactValue(notification.params, secrets) as Map,
        ),
      );

  Future<bool> cancel(String assignmentId, String reason) =>
      executor.cancel(assignmentId);

  Future<Map<String, Object?>> _repositoryScopedPayload(
    Map<String, Object?> payload,
    HostAssignmentContext context,
  ) async {
    final resolver = resolveRepositoryPath;
    if (resolver == null) return _withCorrelation(payload, context);
    final input = payload['input'] is Map
        ? Map<String, Object?>.from(payload['input'] as Map)
        : <String, Object?>{};
    final request = input['request'] is Map
        ? Map<String, Object?>.from(input['request'] as Map)
        : const <String, Object?>{};
    final repository = payload['repository'] is Map
        ? Map<String, Object?>.from(payload['repository'] as Map)
        : const <String, Object?>{};
    final repositoryId = _firstString([
      payload['repositoryId'],
      repository['repositoryId'],
      input['repositoryId'],
      request['repositoryId'],
    ]);
    final suppliedPath = _firstString([
      payload['repositoryPath'],
      input['repositoryPath'],
    ]);
    if (repositoryId == null) {
      if (suppliedPath != null) {
        throw StateError('repositoryPath requires a registered repositoryId');
      }
      return _withCorrelation(payload, context);
    }
    final path = await resolver(repositoryId);
    if (path == null) {
      throw StateError(
          'repository is not registered on this Host: $repositoryId');
    }
    return _withCorrelation(
      {
        ...payload,
        'repositoryId': repositoryId,
        'repositoryPath': path,
        'input': {
          ...input,
          'repositoryId': repositoryId,
          'repositoryPath': path
        },
      },
      context,
    );
  }

  Map<String, Object?> _withCorrelation(
    Map<String, Object?> payload,
    HostAssignmentContext context,
  ) =>
      {
        ...payload,
        'conclave': {
          'workspaceId': context.workspaceId,
          'hostId': context.hostId,
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

  String? _firstString(Iterable<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }
}

typedef WorkerNotificationRelay = FutureOr<void> Function(
  HostAssignmentContext context,
  WorkerRpcNotification notification,
);
