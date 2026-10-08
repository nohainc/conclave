part of '../cloud_connection.dart';

extension _WorkspaceAssignmentHandlers on WorkspaceCloudConnection {
  Future<void> _handleAssignmentStart(Map<String, dynamic> message) async {
    final socket = _transport;
    final payload = message['payload'];
    final requiredFields = [
      'executionWorkspaceId',
      'workspaceRuntimeId',
      'workerId',
      'runId',
      'taskId',
      'attemptId',
      'assignmentId',
      'idempotencyKey',
    ];
    if (socket == null ||
        payload is! Map<String, dynamic> ||
        requiredFields.any((field) => message[field] is! String)) {
      return;
    }

    if (!authorizedWorkspaceIds.contains(message['executionWorkspaceId']) ||
        message['workspaceRuntimeId'] != workspaceRuntimeId) {
      _sendAssignmentError(
        socket,
        message,
        'worker_not_ready',
        retryable: false,
      );
      return;
    }

    final assignmentPayload = payload['snapshot'] is Map
        ? <String, dynamic>{
            ...(payload['snapshot'] as Map).cast<String, dynamic>(),
            if (payload['input'] is Map)
              'input': (payload['input'] as Map).cast<String, dynamic>(),
          }
        : payload;
    final payloadError = _validateAssignmentPayload(assignmentPayload);
    if (payloadError != null) {
      _sendAssignmentError(
        socket,
        message,
        'execution_failed',
        retryable: false,
      );
      return;
    }

    final context = WorkspaceAssignmentContext(
      workspaceId: message['executionWorkspaceId'] as String,
      workspaceRuntimeId: message['workspaceRuntimeId'] as String,
      workerId: message['workerId'] as String,
      runId: message['runId'] as String,
      taskId: message['taskId'] as String,
      attemptId: message['attemptId'] as String,
      assignmentId: message['assignmentId'] as String,
      idempotencyKey: message['idempotencyKey'] as String,
      payload: Map<String, Object?>.from(assignmentPayload),
    );
    final correlation = _assignmentCorrelation(message);
    if (!acceptingNewWork) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {
          'accepted': false,
          'reason': _draining ? 'workspace_draining' : 'workspace_paused'
        },
      )));
      return;
    }
    final journalState = await assignmentJournal?.reconcile();
    final previous = journalState?[context.assignmentId];
    if (previous != null) {
      if (previous.status == AssignmentStatus.completed &&
          previous.result != null) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          correlation,
          {'accepted': true, 'estimatedStartMs': 0},
        )));
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.result',
          correlation,
          {
            'status': 'completed',
            'summary': previous.result!['summary'] ??
                'Assignment replayed from the local journal',
            'output': null,
            'artifactIds': previous.result!['artifactIds'] ?? const [],
          },
        )));
      } else if (previous.status == AssignmentStatus.failed) {
        _sendAssignmentError(
          socket,
          message,
          'execution_failed',
          retryable: true,
        );
      } else if (previous.status == AssignmentStatus.cancelled) {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.cancel.ack',
          correlation,
          {'cancelled': true, 'alreadyTerminated': true},
        )));
      } else {
        socket.send(jsonEncode(_assignmentEnvelope(
          'assignment.ack',
          correlation,
          {
            'accepted': false,
            'reason': 'assignment already exists in local journal',
          },
        )));
      }
      return;
    }
    if (_cancelledBeforeStart.remove(context.assignmentId)) {
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.cancelled,
        context: context,
        result: const {'reason': 'Cancelled before Worker launch'},
      );
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.cancelled',
        correlation,
        {
          'status': 'cancelled',
          'reason': 'Cancelled before Worker launch',
        },
      )));
      return;
    }
    await _recordAssignment(context.assignmentId, AssignmentStatus.received,
        context: context);

    if (assignmentHandler == null) {
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.ack',
        correlation,
        {'accepted': false, 'reason': 'no assignment handler configured'},
      )));
      return;
    }

    _activeAssignments.add(context.assignmentId);
    await _recordAssignment(context.assignmentId, AssignmentStatus.running,
        context: context);
    if (_cancelledBeforeStart.remove(context.assignmentId)) {
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.cancelled,
        context: context,
        result: const {'reason': 'Cancelled before Worker launch'},
      );
      _activeAssignments.remove(context.assignmentId);
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.cancelled',
        correlation,
        {
          'status': 'cancelled',
          'reason': 'Cancelled before Worker launch',
        },
      )));
      return;
    }
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.ack',
      correlation,
      {'accepted': true, 'estimatedStartMs': 0},
    )));
    try {
      final result = await assignmentHandler!(context);
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.result',
        correlation,
        {
          'status': 'completed',
          'summary': result.summary,
          'output': result.output,
          'artifactIds': result.artifactIds,
          if (result.evidence != null)
            'evidence': {
              'observedAt': DateTime.now().toUtc().toIso8601String(),
              ...result.evidence!,
            },
        },
      )));
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.completed,
        context: context,
        result: {'summary': result.summary, 'artifactIds': result.artifactIds},
      );
    } catch (error) {
      final normalizedError =
          error is AssignmentExecutionFailure ? error : null;
      final errorCode = canonicalExecutionErrorCode(normalizedError?.code);
      final errorMessage = executionErrorMessage(errorCode);
      socket.send(jsonEncode(_assignmentEnvelope(
        'assignment.error',
        correlation,
        {
          'status': 'failed',
          'error': {
            'code': errorCode,
            'message': errorMessage,
            'retryable': normalizedError?.retryable ?? true,
          },
        },
      )));
      await _recordAssignment(
        context.assignmentId,
        AssignmentStatus.failed,
        context: context,
        result: {
          'error': errorMessage,
          'errorCode': errorCode,
        },
      );
    } finally {
      _activeAssignments.remove(context.assignmentId);
    }
  }

  Future<void> _handleAssignmentCancel(Map<String, dynamic> message) async {
    final socket = _transport;
    if (socket == null ||
        message['assignmentId'] is! String ||
        message['executionWorkspaceId'] != workspaceId ||
        message['workspaceRuntimeId'] != workspaceRuntimeId) {
      return;
    }
    final assignmentId = message['assignmentId'] as String;
    final payload = message['payload'];
    final reason = payload is Map && payload['reason'] is String
        ? payload['reason'] as String
        : 'Cloud requested cancellation';
    var cancelled = false;
    if (_activeAssignments.contains(assignmentId) &&
        assignmentCancellationHandler != null) {
      cancelled = await assignmentCancellationHandler!(assignmentId, reason);
    }
    if (!cancelled) {
      final previous = (await assignmentJournal?.reconcile())?[assignmentId];
      final terminal = previous != null &&
          {
            AssignmentStatus.completed,
            AssignmentStatus.failed,
            AssignmentStatus.cancelled,
            AssignmentStatus.reconciled,
          }.contains(previous.status);
      if (!terminal) {
        if (_cancelledBeforeStart.length >= 1024) {
          _cancelledBeforeStart.remove(_cancelledBeforeStart.first);
        }
        _cancelledBeforeStart.add(assignmentId);
        cancelled = true;
      }
    }
    if (cancelled &&
        _activeAssignments.contains(assignmentId) &&
        assignmentCancellationHandler != null) {
      // Close the narrow interval between adding the assignment to the active
      // set and the Worker executor reserving its process slot.
      if (await assignmentCancellationHandler!(assignmentId, reason)) {
        _cancelledBeforeStart.remove(assignmentId);
      }
    }
    final alreadyTerminated = !_activeAssignments.contains(assignmentId);
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.cancel.ack',
      _assignmentCorrelation(message),
      {
        'cancelled': cancelled,
        'alreadyTerminated': alreadyTerminated,
      },
    )));
  }

  String? _validateAssignmentPayload(Object? rawPayload) {
    if (rawPayload is! Map<String, dynamic>) {
      return 'Assignment payload must be an object';
    }
    final sessionPolicy = rawPayload['sessionPolicy'] ?? 'stateless';
    final sessionKey = rawPayload['sessionKey'];
    if (!const {'stateless', 'durable_session'}.contains(sessionPolicy) ||
        (sessionKey != null &&
            (sessionKey is! String ||
                sessionKey.trim().isEmpty ||
                sessionKey.length > 256)) ||
        (sessionPolicy == 'stateless' && sessionKey != null) ||
        (sessionPolicy == 'durable_session' && sessionKey == null)) {
      return 'Assignment session policy is invalid';
    }
    final statelessContext = rawPayload['statelessContext'];
    if (statelessContext != null) {
      if (sessionPolicy != 'stateless' || statelessContext is! Map) {
        return 'Invalid stateless Conversation context';
      }
      try {
        ConversationBootstrap.fromJson(
            Map<String, Object?>.from(statelessContext));
      } on FormatException {
        return 'Invalid stateless Conversation context';
      }
    }
    final sessionContext = rawPayload['workerSession'];
    if (sessionContext != null) {
      try {
        if (sessionContext is! Map || sessionPolicy != 'durable_session') {
          return 'Assignment Worker Session is invalid';
        }
        final context = WorkerSessionContext.fromJson(
          Map<String, Object?>.from(sessionContext),
        );
        if (context.workerId != rawPayload['workerId']) {
          return 'Assignment Worker Session belongs to another Worker';
        }
      } on FormatException {
        return 'Assignment Worker Session is invalid';
      }
    }
    if (rawPayload['snapshot'] == null &&
        rawPayload['objective'] == null &&
        rawPayload['role'] == null) {
      for (final field in [
        'assignmentId',
        'executionWorkspaceId',
        'spaceId',
        'runId',
        'taskId',
        'attemptId',
        'requestedByUserId',
        'workspaceRuntimeId',
        'workerId',
        'engineVersion',
        'profileDefinitionId',
        'profileReleaseVersion',
        'config',
        'permissions',
        'contextRefs',
        'timeoutMs',
        'idempotencyKey',
      ]) {
        if (!rawPayload.containsKey(field)) {
          return 'Assignment field $field is required';
        }
      }
      if (rawPayload['config'] is! Map ||
          rawPayload['permissions'] is! List ||
          rawPayload['contextRefs'] is! List ||
          rawPayload['timeoutMs'] is! int ||
          (rawPayload['timeoutMs'] as int) < 1000 ||
          (rawPayload['timeoutMs'] as int) > 2147483647) {
        return 'Assignment snapshot fields are invalid';
      }
      return null;
    }
    for (final field in [
      'objective',
      'role',
      'workerId',
      'engineVersion',
      'profileDefinitionId',
    ]) {
      if (rawPayload[field] is! String ||
          (rawPayload[field] as String).trim().isEmpty) {
        return 'Assignment field $field is required';
      }
    }
    final profileReleaseVersion = rawPayload['profileReleaseVersion'];
    if (profileReleaseVersion is! int || profileReleaseVersion < 1) {
      return 'Assignment profileReleaseVersion must be a positive integer';
    }
    if (rawPayload['input'] is! Map) {
      return 'Assignment input must be an object';
    }
    final artifactIds = rawPayload['contextArtifactIds'];
    if (artifactIds is! List || artifactIds.any((id) => id is! String)) {
      return 'Assignment contextArtifactIds must be a string array';
    }
    final timeoutMs = rawPayload['timeoutMs'];
    if (timeoutMs is! int || timeoutMs < 1000 || timeoutMs > 2147483647) {
      return 'Assignment timeoutMs must be between 1000 and 2147483647 milliseconds';
    }
    final repository = rawPayload['repository'];
    if (repository != null) {
      if (repository is! Map ||
          repository['repositoryId'] is! String ||
          (repository['repositoryId'] as String).trim().isEmpty ||
          repository['revision'] is! String ||
          (repository['revision'] as String).trim().isEmpty) {
        return 'Assignment repository must contain repositoryId and revision';
      }
    }
    return null;
  }

  void _sendAssignmentError(
    WorkspaceTransport socket,
    Map<String, dynamic> message,
    String code, {
    required bool retryable,
  }) {
    final canonicalCode = canonicalExecutionErrorCode(code);
    socket.send(jsonEncode(_assignmentEnvelope(
      'assignment.error',
      _assignmentCorrelation(message),
      {
        'status': 'failed',
        'error': {
          'code': canonicalCode,
          'message': executionErrorMessage(canonicalCode),
          'retryable': retryable,
        },
      },
    )));
  }

  Future<void> _recordAssignment(
    String assignmentId,
    AssignmentStatus status, {
    WorkspaceAssignmentContext? context,
    Map<String, Object?>? correlation,
    Map<String, Object?>? result,
  }) async {
    final journal = assignmentJournal;
    if (journal == null) return;
    await journal.append(AssignmentRecord(
      assignmentId: assignmentId,
      status: status,
      updatedAt: DateTime.now().toUtc(),
      workspaceId:
          context?.workspaceId ?? correlation?['workspaceId'] as String?,
      workspaceRuntimeId: context?.workspaceRuntimeId ??
          correlation?['workspaceRuntimeId'] as String?,
      workerId: context?.workerId ?? correlation?['workerId'] as String?,
      runId: context?.runId ?? correlation?['runId'] as String?,
      taskId: context?.taskId ?? correlation?['taskId'] as String?,
      attemptId: context?.attemptId ?? correlation?['attemptId'] as String?,
      idempotencyKey:
          context?.idempotencyKey ?? correlation?['idempotencyKey'] as String?,
      result: result,
    ));
  }
}
