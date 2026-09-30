import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'worker_deadline_controller.dart';
import 'worker_logger.dart';
import 'worker_failure.dart';

class WorkerIdentity {
  const WorkerIdentity({
    required this.workerTypeId,
    required this.workerVersion,
    this.stateSchemaVersion = 1,
    this.capabilities = const ['initialize'],
  });

  final String workerTypeId;
  final String workerVersion;
  final int stateSchemaVersion;
  final List<String> capabilities;
}

typedef WorkerProbeHandler =
    FutureOr<ProbeResult> Function(ProbeRequest request);
typedef WorkerExecuteHandler =
    Future<String> Function(
      ExecuteRequest request,
      WorkerExecutionContext context,
    );

/// Context supplied to a Worker implementation for reporting assignment progress.
class WorkerExecutionContext {
  const WorkerExecutionContext._({required this.request, required this.emit});

  final ExecuteRequest request;
  final Future<void> Function(WorkerProgress progress) emit;

  Future<void> reportProgress(double percentage, {String? message}) => emit(
    WorkerProgress(
      requestId: request.requestId,
      assignmentId: request.assignmentId,
      percentage: percentage,
      message: message,
    ),
  );
}

/// Provider-neutral NDJSON server for standalone Dart Worker executables.
///
/// Cancellation is process-owned: Workspace may terminate the Worker process
/// tree at any time. The protocol server also enforces each request deadline.
class WorkerRuntime {
  const WorkerRuntime({
    required this.identity,
    this.onProbe,
    this.onExecute,
    this.logger = const WorkerLogger(),
  });

  final WorkerIdentity identity;
  final WorkerProbeHandler? onProbe;
  final WorkerExecuteHandler? onExecute;
  final WorkerLogger logger;

  Future<void> run({Stream<List<int>>? input, IOSink? output}) async {
    final lines = (input ?? stdin)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final sink = output ?? stdout;
    await for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final frame = decodeWorkerFrame(line);
        switch (frame) {
          case InitializeRequest():
            await _initialize(frame, sink);
          case ProbeRequest():
            await _probe(frame, sink);
          case ExecuteRequest():
            await _execute(frame, sink);
          default:
            throw FormatException('unsupported request frame: ${frame.type}');
        }
      } on Object {
        logger.log(
          'error',
          'request.failed',
          context: {
            'protocolStage': 'protocol',
            'errorCode': WorkerIssueCode.malformedFrame,
          },
        );
      }
    }
  }

  Future<void> _initialize(InitializeRequest request, IOSink sink) async {
    if (request.workerTypeId != identity.workerTypeId) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.workerTypeMismatch,
          message: 'Worker type does not match this executable',
        ),
      );
      return;
    }
    if (request.expectedWorkerVersion != identity.workerVersion) {
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.workerVersionMismatch,
          message: 'Worker version does not match the requested version',
        ),
      );
      return;
    }
    await _write(
      sink,
      InitializeResult(
        requestId: request.requestId,
        workerTypeId: identity.workerTypeId,
        workerVersion: identity.workerVersion,
        stateSchemaVersion: identity.stateSchemaVersion,
        capabilities: identity.capabilities,
        protocolVersion: request.protocolVersion,
      ),
    );
  }

  Future<void> _probe(ProbeRequest request, IOSink sink) async {
    try {
      final handler = onProbe;
      if (handler == null) {
        await _write(
          sink,
          ProbeResult(
            requestId: request.requestId,
            mode: request.mode,
            ready: false,
            checks: const [],
            issueCode: WorkerIssueCode.providerToolUnavailable,
            diagnostics: 'Worker probe implementation is not configured',
          ),
        );
        return;
      }
      final result = await handler(request);
      if (result.requestId != request.requestId ||
          result.mode != request.mode) {
        throw StateError('probe handler returned a mismatched response');
      }
      await _write(sink, result);
    } on Object {
      logger.log(
        'error',
        'probe.failed',
        context: {
          'protocolStage': 'probe',
          'requestId': request.requestId,
          'errorCode': WorkerIssueCode.workerInternalFailure,
        },
      );
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          code: WorkerIssueCode.workerInternalFailure,
          message: 'Worker probe failed',
        ),
      );
    }
  }

  Future<void> _execute(ExecuteRequest request, IOSink sink) async {
    var active = true;
    final context = WorkerExecutionContext._(
      request: request,
      emit: (progress) async {
        if (!active) return;
        if (progress.requestId != request.requestId ||
            progress.assignmentId != request.assignmentId) {
          throw StateError('progress does not match the active assignment');
        }
        await _write(sink, progress);
      },
    );
    final deadline = WorkerDeadlineController(
      Duration(milliseconds: request.timeoutMs),
    );
    try {
      final handler = onExecute;
      if (handler == null) {
        await _write(
          sink,
          WorkerErrorFrame(
            requestId: request.requestId,
            assignmentId: request.assignmentId,
            code: WorkerIssueCode.providerToolUnavailable,
            message: 'Worker execution implementation is not configured',
          ),
        );
        return;
      }
      final output = await deadline.run(() => handler(request, context));
      active = false;
      await _write(
        sink,
        WorkerResult(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          output: output,
        ),
      );
    } on WorkerFailure catch (failure) {
      active = false;
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: failure.code,
          message: failure.message,
          retryable: failure.retryable,
          diagnostics: failure.diagnostics,
        ),
      );
    } on TimeoutException {
      active = false;
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.deadlineExceeded,
          message: 'Worker assignment exceeded its deadline',
        ),
      );
    } on Object {
      active = false;
      logger.log(
        'error',
        'assignment.failed',
        context: {
          'protocolStage': 'execute',
          'assignmentId': request.assignmentId,
          'requestId': request.requestId,
          'errorCode': WorkerIssueCode.workerInternalFailure,
        },
      );
      await _write(
        sink,
        WorkerErrorFrame(
          requestId: request.requestId,
          assignmentId: request.assignmentId,
          code: WorkerIssueCode.workerInternalFailure,
          message: 'Worker assignment failed',
        ),
      );
    }
  }

  Future<void> _write(IOSink sink, WorkerFrame frame) async {
    sink.writeln(frame.encode());
    await sink.flush();
  }
}
