enum WebWorkerStatus {
  connecting,
  waiting,
  working,
  completed,
  expired,
  unavailable
}

class WebWorkerSession {
  WebWorkerSession(
      {required this.sessionId,
      required this.provider,
      required this.leaseExpiresAt})
      : status = WebWorkerStatus.connecting;
  final String sessionId;
  final String provider;
  DateTime leaseExpiresAt;
  WebWorkerStatus status;

  bool get leaseValid =>
      DateTime.now().isBefore(leaseExpiresAt) &&
      status != WebWorkerStatus.expired;
}

abstract interface class WebWorkerRelay {
  Future<Map<String, Object?>> createSession(String provider);
  Future<Map<String, Object?>> getContext(String sessionId);
  Future<Map<String, Object?>> submitResult(
      String sessionId, Map<String, Object?> result);
  Future<void> sendFollowUp(String sessionId, String message);
}

class WebAiWorker {
  WebAiWorker(this.relay);
  final WebWorkerRelay relay;

  Future<WebWorkerSession> start(String provider) async {
    final response = await relay.createSession(provider);
    final expires = DateTime.parse(response['leaseExpiresAt']! as String);
    final session = WebWorkerSession(
      sessionId: response['sessionId']! as String,
      provider: provider,
      leaseExpiresAt: expires,
    );
    session.status = WebWorkerStatus.waiting;
    return session;
  }

  Future<Map<String, Object?>> receiveTask(WebWorkerSession session) async {
    _requireLease(session);
    session.status = WebWorkerStatus.working;
    return relay.getContext(session.sessionId);
  }

  Future<Map<String, Object?>> submit(
      WebWorkerSession session, Map<String, Object?> result) async {
    _requireLease(session);
    final response = await relay.submitResult(session.sessionId, result);
    session.status = WebWorkerStatus.completed;
    return response;
  }

  Future<void> followUp(WebWorkerSession session, String message) async {
    _requireLease(session);
    await relay.sendFollowUp(session.sessionId, message);
  }

  void _requireLease(WebWorkerSession session) {
    if (!session.leaseValid) {
      session.status = WebWorkerStatus.expired;
      throw StateError('web worker session lease expired');
    }
  }
}
