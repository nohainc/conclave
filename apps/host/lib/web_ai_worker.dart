const webAiWorkerManifest = <String, Object?>{
  'workerId': 'conclave.web-ai',
  'version': '0.2.0',
  'displayName': 'Web AI Worker',
  'description':
      'Subscription-backed web AI Worker using a Cloud mailbox relay',
  'publisher': 'conclave-official',
  'channel': 'development',
  'protocolVersion': '4.0',
  'minimumHostVersion': '0.1.0',
  'roles': ['researcher', 'reviewer', 'implementer'],
  'capabilities': ['web_ai', 'interactive_session', 'structured_output'],
  'permissions': ['network:cloud-relay'],
  'credentialRequirements': [
    {
      'name': 'web_account',
      'authMode': 'oauth_browser',
      'sharingPolicy': 'private_only',
      'required': true,
    },
  ],
  'credentialSharingPolicy': 'private_only',
  'sessionModes': ['reuse_session'],
  'concurrencyModel': {
    'maxConcurrentAssignments': 1,
    'persistentRuntime': true,
    'isolation': 'process',
  },
  'entrypoint': 'host:web_ai_worker',
  'billingModes': ['subscription'],
  'digest': 'sha256:development',
  'signature': 'development',
};

enum WebWorkerStatus {
  connecting,
  reconnecting,
  waiting,
  waitingForUser,
  working,
  quotaExceeded,
  completed,
  expired,
  unavailable,
}

class WebWorkerSession {
  WebWorkerSession({
    required this.sessionId,
    required this.provider,
    required this.credentialProfileId,
    required this.assignmentId,
    required this.leaseExpiresAt,
    this.attemptId,
  }) : status = WebWorkerStatus.connecting;

  String sessionId;
  final String provider;
  final String credentialProfileId;
  final String assignmentId;
  final String? attemptId;
  DateTime leaseExpiresAt;
  WebWorkerStatus status;

  bool get leaseValid =>
      DateTime.now().isBefore(leaseExpiresAt) &&
      status != WebWorkerStatus.expired;
}

abstract interface class WebWorkerRelay {
  Future<Map<String, Object?>> createSession({
    required String provider,
    required String credentialProfileId,
    required String assignmentId,
  });

  Future<Map<String, Object?>> reconnectSession({
    required String sessionId,
    required String credentialProfileId,
  });

  Future<Map<String, Object?>> getContext(
      String sessionId, String assignmentId);

  Future<Map<String, Object?>> submitResult(
      String sessionId, String assignmentId, Map<String, Object?> result);

  Future<void> reportStatus(
      String sessionId, String assignmentId, WebWorkerStatus status);

  Future<void> sendFollowUp(String sessionId, String message);
}

class WebAiWorker {
  WebAiWorker(this.relay);
  final WebWorkerRelay relay;
  final _sessionProfiles = <String, String>{};

  Future<WebWorkerSession> start(
    String provider, {
    required String credentialProfileId,
    required String assignmentId,
    Iterable<String> fallbackProviders = const [],
  }) async {
    if (credentialProfileId.trim().isEmpty) {
      throw ArgumentError.value(
          credentialProfileId, 'credentialProfileId', 'must not be empty');
    }
    if (assignmentId.trim().isEmpty) {
      throw ArgumentError.value(
          assignmentId, 'assignmentId', 'must not be empty');
    }
    Object? lastError;
    for (final candidate in <String>[provider, ...fallbackProviders]) {
      try {
        final response = await relay.createSession(
          provider: candidate,
          credentialProfileId: credentialProfileId,
          assignmentId: assignmentId,
        );
        final sessionId = _requiredString(response, 'sessionId');
        final returnedProfile = response['credentialProfileId'];
        if (returnedProfile is String &&
            returnedProfile != credentialProfileId) {
          throw StateError('web session credential Profile mismatch');
        }
        final session = WebWorkerSession(
          sessionId: sessionId,
          provider: candidate,
          credentialProfileId: credentialProfileId,
          assignmentId: assignmentId,
          attemptId: response['attemptId'] as String?,
          leaseExpiresAt:
              DateTime.parse(_requiredString(response, 'leaseExpiresAt')),
        );
        _claimSession(session);
        session.status =
            _statusFrom(response['status']) ?? WebWorkerStatus.waiting;
        return session;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw StateError('web AI Worker unavailable: $lastError');
  }

  Future<void> reconnect(WebWorkerSession session) async {
    session.status = WebWorkerStatus.reconnecting;
    try {
      final response = await relay.reconnectSession(
        sessionId: session.sessionId,
        credentialProfileId: session.credentialProfileId,
      );
      final returnedProfile = response['credentialProfileId'];
      if (returnedProfile is String &&
          returnedProfile != session.credentialProfileId) {
        throw StateError('web session credential Profile mismatch');
      }
      final nextSessionId = _requiredString(response, 'sessionId');
      session.sessionId = nextSessionId;
      session.leaseExpiresAt =
          DateTime.parse(_requiredString(response, 'leaseExpiresAt'));
      _claimSession(session);
      session.status =
          _statusFrom(response['status']) ?? WebWorkerStatus.waiting;
    } catch (_) {
      session.status = WebWorkerStatus.expired;
      rethrow;
    }
  }

  Future<Map<String, Object?>> receiveTask(WebWorkerSession session) async {
    _requireLease(session);
    session.status = WebWorkerStatus.working;
    final response =
        await relay.getContext(session.sessionId, session.assignmentId);
    final status = _statusFrom(response['status']);
    if (status != null) session.status = status;
    return response['context'] is Map
        ? Map<String, Object?>.from(response['context'] as Map)
        : response;
  }

  Future<Map<String, Object?>> submit(
      WebWorkerSession session, Map<String, Object?> result) async {
    _requireLease(session);
    final response =
        await relay.submitResult(session.sessionId, session.assignmentId, {
      ...result,
      'assignmentId': session.assignmentId,
      if (session.attemptId != null) 'attemptId': session.attemptId,
      'credentialProfileId': session.credentialProfileId,
    });
    final status = _statusFrom(response['status']);
    session.status = status ?? WebWorkerStatus.completed;
    return response;
  }

  Future<void> reportStatus(
      WebWorkerSession session, WebWorkerStatus status) async {
    _requireLease(session);
    await relay.reportStatus(session.sessionId, session.assignmentId, status);
    session.status = status;
  }

  Future<void> followUp(WebWorkerSession session, String message) async {
    _requireLease(session);
    await relay.sendFollowUp(session.sessionId, message);
  }

  void _claimSession(WebWorkerSession session) {
    final previousProfile = _sessionProfiles[session.sessionId];
    if (previousProfile != null &&
        previousProfile != session.credentialProfileId) {
      throw StateError(
          'web session is already owned by another Credential Profile');
    }
    _sessionProfiles[session.sessionId] = session.credentialProfileId;
  }

  void _requireLease(WebWorkerSession session) {
    if (!session.leaseValid) {
      session.status = WebWorkerStatus.expired;
      throw StateError('web worker session lease expired');
    }
  }

  static String _requiredString(Map<String, Object?> response, String key) {
    final value = response[key];
    if (value is! String || value.isEmpty) {
      throw StateError('web relay response requires $key');
    }
    return value;
  }

  static WebWorkerStatus? _statusFrom(Object? value) => switch (value) {
        'waiting' => WebWorkerStatus.waiting,
        'waiting_for_user' => WebWorkerStatus.waitingForUser,
        'quota_exceeded' => WebWorkerStatus.quotaExceeded,
        'reconnecting' => WebWorkerStatus.reconnecting,
        'working' => WebWorkerStatus.working,
        'completed' => WebWorkerStatus.completed,
        'expired' => WebWorkerStatus.expired,
        'unavailable' => WebWorkerStatus.unavailable,
        _ => null,
      };
}
