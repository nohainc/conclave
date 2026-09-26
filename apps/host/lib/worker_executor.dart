import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'cloud_connection.dart';
import 'worker_protocol.dart';
import 'process_tree.dart';
import 'runtime_capabilities.dart';
import 'workstream_directory.dart';
import 'worker_trust_policy.dart';
import 'v7_adapter_protocol.dart';

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

class WorkerProcessSpec {
  const WorkerProcessSpec({
    required this.workerId,
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.allowedEnvironmentVariables = const {},
    this.secretValues = const {},
    this.maxConcurrentAssignments = 1,
  });

  final String workerId;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final Set<String> allowedEnvironmentVariables;
  final Set<String> secretValues;
  final int maxConcurrentAssignments;

  WorkerProcessSpec copyWith({
    String? workingDirectory,
    int? maxConcurrentAssignments,
  }) =>
      WorkerProcessSpec(
        workerId: workerId,
        executable: executable,
        arguments: arguments,
        workingDirectory: workingDirectory ?? this.workingDirectory,
        environment: environment,
        allowedEnvironmentVariables: allowedEnvironmentVariables,
        secretValues: secretValues,
        maxConcurrentAssignments:
            maxConcurrentAssignments ?? this.maxConcurrentAssignments,
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

typedef WorkerProcessLauncher = Future<Process> Function(
    WorkerProcessSpec spec);
typedef WorkerProcessResolver = FutureOr<WorkerProcessSpec?> Function(
  String workerId,
);
typedef V7AdapterResolver = FutureOr<V7AdapterLaunch?> Function(
    String workerId);
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
  })  : _launcher = launcher ?? _launch,
        _terminator = terminator ?? terminateProcessTree;

  final WorkerProcessLauncher _launcher;
  final WorkerProcessTerminator _terminator;
  int _requestSequence = 0;
  int _operationSequence = 0;
  final _activeProcesses = <String, Process>{};
  final _activeResponses = <String, Completer<Map<String, Object?>>>{};
  final _cancelledOperations = <String>{};
  final _activeCancellations = <String, void Function()>{};
  final _workerGates = <String, _WorkerExecutionGate>{};
  final _queuedOperations = <String, _QueuedWorkerExecution>{};
  final _reservedOperations = <String>{};
  final _cancelledBeforeLaunch = <String>{};
  final _operationWorkers = <String, String>{};

  static Future<Process> _launch(WorkerProcessSpec spec) {
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
      ),
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
    bool validateOnly = false,
    Duration timeout = const Duration(minutes: 5),
    int maxStdoutBytes = 4 * 1024 * 1024,
    int maxStderrBytes = 1024 * 1024,
    String? operationId,
    V7AdapterProgressHandler? onProgress,
  }) async {
    if (maxStdoutBytes <= 0 || maxStderrBytes <= 0) {
      throw ArgumentError('adapter output limits must be positive');
    }
    final processId = operationId ??
        'host-adapter-${DateTime.now().microsecondsSinceEpoch}-${++_operationSequence}';
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
      throw TimeoutException('Adapter timed out before launch', timeout);
    }
    try {
      return await _executeV7AdapterProcess(
        spec,
        workerTypeId: workerTypeId,
        adapterVersion: adapterVersion,
        prompt: prompt,
        config: config,
        model: model,
        validateOnly: validateOnly,
        timeout: remaining,
        maxStdoutBytes: maxStdoutBytes,
        maxStderrBytes: maxStderrBytes,
        operationId: processId,
        onProgress: onProgress,
      );
    } finally {
      _releaseWorkerSlot(spec.workerId, processId);
    }
  }

  Future<Map<String, Object?>> _executeV7AdapterProcess(
    WorkerProcessSpec spec, {
    required String workerTypeId,
    required String adapterVersion,
    required String prompt,
    required Map<String, Object?> config,
    required String? model,
    required bool validateOnly,
    required Duration timeout,
    required int maxStdoutBytes,
    required int maxStderrBytes,
    required String operationId,
    V7AdapterProgressHandler? onProgress,
  }) async {
    final process = await _launcher(spec);
    final elapsed = Stopwatch()..start();
    if (_cancelledBeforeLaunch.remove(operationId)) {
      await _terminateGracefully(process);
      throw ProcessException(
          'cancelled', const [], 'Adapter cancelled before launch');
    }
    _activeProcesses[operationId] = process;
    var stdoutBytes = 0;
    var stderrBytes = 0;
    final stderrPreview = StringBuffer();
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
      unawaited(_terminator(process, force: true));
    }

    _activeCancellations[operationId] = () {
      fail(ProcessException(
          'cancelled', const [], 'Adapter assignment cancelled'));
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
      if (stderrPreview.length < 4096) {
        stderrPreview.write(utf8.decode(chunk, allowMalformed: true));
      }
      if (stderrBytes > maxStderrBytes) {
        fail(StateError('adapter stderr exceeded $maxStderrBytes bytes'));
      }
    });
    unawaited(process.exitCode.then((code) {
      if (!failed && pending.values.any((item) => !item.isCompleted)) {
        fail(StateError('adapter exited with code $code before replying'));
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
        'protocolVersion': v7AdapterProtocolVersion,
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
        throw StateError(redactSecrets(
          'adapter ${frame['code']}: ${frame['message']}',
          spec.secretValues,
        ));
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
      final version = await request('version.request', 'version.result', {});
      if (version['adapterVersion'] != adapterVersion ||
          version['protocolVersion'] != v7AdapterProtocolVersion) {
        throw StateError('adapter version handshake mismatch');
      }
      final health = await request('health.request', 'health.result', {});
      if (health['healthy'] != true) {
        throw StateError('adapter health check failed');
      }
      final validation = await request('validate.request', 'validate.result', {
        'config': config,
      });
      if (validation['ready'] != true) {
        throw StateError(redactSecrets(
          'adapter validation failed: ${jsonEncode(validation['issues'])}',
          spec.secretValues,
        ));
      }
      if (validateOnly) {
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException(
              'adapter credential validation timed out', timeout);
        }
        await process.stdin.close();
        final exitCode = await process.exitCode.timeout(remaining);
        if (exitCode != 0) {
          throw StateError('adapter exited after credential validation');
        }
        return {
          'validated': true,
          'models':
              List<String>.from(validation['models'] as List? ?? const []),
        };
      }
      expectedAssignmentId = operationId;
      final executeId =
          'host-${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
      expectedProgressRequestId = executeId;
      final executeResponse = Completer<Map<String, Object?>>();
      pending[executeId] = executeResponse;
      process.stdin.writeln(serializeV7AdapterFrame({
        'type': 'execute.request',
        'protocolVersion': v7AdapterProtocolVersion,
        'requestId': executeId,
        'assignmentId': operationId,
        'prompt': prompt,
        if (model != null && model.isNotEmpty) 'model': model,
      }));
      await process.stdin.flush();
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        fail(TimeoutException('adapter execution timed out', timeout));
        throw TimeoutException('adapter execution timed out', timeout);
      }
      final result =
          await executeResponse.future.timeout(remaining, onTimeout: () {
        fail(TimeoutException('adapter execution timed out', timeout));
        throw TimeoutException(
          'adapter execution timed out; stderr: ${redactSecrets(stderrPreview.toString(), spec.secretValues)}',
          timeout,
        );
      });
      if (result['type'] == 'error') {
        throw StateError(redactSecrets(
          'adapter ${result['code']}: ${result['message']}',
          spec.secretValues,
        ));
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
      await _terminateGracefully(process);
      _activeProcesses.remove(operationId);
      _activeCancellations.remove(operationId);
      _cancelledOperations.remove(operationId);
    }
  }

  /// Runs an installed adapter's startup and declared health check without
  /// sending Worker configuration, credentials, or an assignment prompt.
  Future<void> checkV7AdapterHealth(
    WorkerProcessSpec spec, {
    required String workerTypeId,
    required String adapterVersion,
    required String healthCheckMode,
    Duration timeout = const Duration(seconds: 5),
    int maxStdoutBytes = 1024 * 1024,
    int maxStderrBytes = 256 * 1024,
  }) async {
    if (!const {'protocol', 'process_exit'}.contains(healthCheckMode) ||
        timeout <= Duration.zero ||
        maxStdoutBytes <= 0 ||
        maxStderrBytes <= 0) {
      throw ArgumentError('adapter health-check policy is invalid');
    }
    final process = await _launcher(spec);
    final elapsed = Stopwatch()..start();
    var stdoutBytes = 0;
    var stderrBytes = 0;
    var failed = false;
    Completer<Map<String, Object?>>? pending;
    String? expectedRequestId;
    void fail(Object error) {
      if (failed) return;
      failed = true;
      if (pending != null && !pending!.isCompleted) {
        pending!.completeError(error);
      }
      unawaited(_terminator(process, force: true));
    }

    final stdoutSubscription = process.stdout
        .transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (chunk, sink) {
            stdoutBytes += chunk.length;
            if (stdoutBytes > maxStdoutBytes) {
              fail(StateError('adapter health stdout exceeded its limit'));
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
            if (frame['requestId'] == expectedRequestId &&
                pending != null &&
                !pending!.isCompleted) {
              pending!.complete(frame);
            }
          } on Object catch (error) {
            fail(error);
          }
        });
    final stderrSubscription = process.stderr.listen((chunk) {
      stderrBytes += chunk.length;
      if (stderrBytes > maxStderrBytes) {
        fail(StateError('adapter health stderr exceeded its limit'));
      }
    });
    unawaited(process.exitCode.then((code) {
      if (!failed && pending != null && !pending!.isCompleted) {
        fail(StateError('adapter exited with code $code during health check'));
      }
    }));
    Future<Map<String, Object?>> request(
      String type,
      String responseType,
      Map<String, Object?> fields,
    ) async {
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('adapter health check timed out', timeout);
      }
      final requestId =
          'health-${DateTime.now().microsecondsSinceEpoch}-${++_requestSequence}';
      expectedRequestId = requestId;
      final response = Completer<Map<String, Object?>>();
      pending = response;
      process.stdin.writeln(serializeV7AdapterFrame({
        'type': type,
        'protocolVersion': v7AdapterProtocolVersion,
        'requestId': requestId,
        ...fields,
      }));
      await process.stdin.flush();
      final frame = await response.future.timeout(remaining, onTimeout: () {
        fail(TimeoutException('adapter $type timed out', remaining));
        throw TimeoutException('adapter $type timed out', remaining);
      });
      pending = null;
      if (frame['type'] != responseType) {
        throw StateError('adapter returned an unexpected health response');
      }
      if (frame['type'] == 'error') {
        throw StateError('adapter health error: ${frame['message']}');
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
        throw StateError('adapter initialize version mismatch');
      }
      final version = await request('version.request', 'version.result', {});
      if (version['adapterVersion'] != adapterVersion ||
          version['protocolVersion'] != v7AdapterProtocolVersion) {
        throw StateError('adapter version handshake mismatch');
      }
      if (healthCheckMode == 'protocol') {
        final health = await request('health.request', 'health.result', {});
        if (health['healthy'] != true) {
          throw StateError('adapter protocol health check failed');
        }
      } else {
        await process.stdin.close();
        final remaining = timeout - elapsed.elapsed;
        if (remaining <= Duration.zero) {
          throw TimeoutException(
              'adapter process-exit check timed out', timeout);
        }
        final code = await process.exitCode.timeout(remaining);
        if (code != 0) {
          throw StateError('adapter process-exit health check failed');
        }
      }
    } catch (_) {
      if (!failed) fail(StateError('adapter health check failed'));
      rethrow;
    } finally {
      await process.stdin.close();
      await stdoutSubscription.cancel();
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
    await _terminateGracefully(process);
    return true;
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
    } finally {
      _queuedOperations.remove(operationId);
    }
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
}

Map<String, String> safeWorkerEnvironment(
  Map<String, String> requested, {
  Set<String> allowedNames = const {},
}) {
  final environment = <String, String>{};
  for (final name in const [
    'PATH',
    'HOME',
    'USERPROFILE',
    'TMPDIR',
    'TMP',
    'TEMP',
    'SystemRoot',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
  ]) {
    final value = Platform.environment[name];
    if (value != null && value.isNotEmpty) environment[name] = value;
  }
  // Worker processes are non-interactive. Prevent language runtimes from
  // blocking on first-run telemetry prompts while the Host is executing.
  environment['DART_SUPPRESS_ANALYTICS'] = '1';
  for (final entry in requested.entries) {
    if (allowedNames.contains(entry.key)) environment[entry.key] = entry.value;
  }
  return environment;
}

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
    final v7Adapter = await resolveV7Adapter?.call(workerId);
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
        throw StateError('assignment permissions must be a list of strings');
      }
      final denied = requestedPermissions.whereType<String>().firstWhere(
          (permission) => !runtimePermissionAllowed(permission, allowed),
          orElse: () => '');
      if (denied.isNotEmpty) {
        throw StateError('assignment permission is not allowed: $denied');
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
    return jsonEncode(payload);
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
      throw StateError('requested model is outside the local Worker policy');
    }
    final selected = requested ?? adapter.defaultModel;
    if (selected != null &&
        adapter.allowedModels.isNotEmpty &&
        !adapter.allowedModels.contains(selected)) {
      throw StateError('default model is outside the local Worker policy');
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
