import 'package:conclave_host/web_ai_worker.dart';
import 'package:test/test.dart';

class FakeRelay implements WebWorkerRelay {
  int createAttempts = 0;
  String? lastProfile;
  String? lastAssignment;
  WebWorkerStatus? reportedStatus;
  bool waitingForUser = false;
  bool quotaExceeded = false;

  @override
  Future<Map<String, Object?>> createSession({
    required String provider,
    required String credentialProfileId,
    required String assignmentId,
  }) async {
    createAttempts++;
    lastProfile = credentialProfileId;
    lastAssignment = assignmentId;
    if (provider == 'unavailable') throw StateError('quota');
    return {
      'sessionId': '$provider-session-$createAttempts',
      'credentialProfileId': credentialProfileId,
      if (quotaExceeded) 'status': 'quota_exceeded',
      'leaseExpiresAt':
          DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
    };
  }

  @override
  Future<Map<String, Object?>> reconnectSession({
    required String sessionId,
    required String credentialProfileId,
  }) async =>
      {
        'sessionId': '$sessionId-reconnected',
        'credentialProfileId': credentialProfileId,
        'leaseExpiresAt':
            DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      };

  @override
  Future<Map<String, Object?>> getContext(
          String sessionId, String assignmentId) async =>
      {
        if (waitingForUser) 'status': 'waiting_for_user',
        'context': {'taskId': 'task-1'}
      };

  @override
  Future<Map<String, Object?>> submitResult(String sessionId,
          String assignmentId, Map<String, Object?> result) async =>
      {'accepted': true, 'credentialProfileId': result['credentialProfileId']};

  @override
  Future<void> reportStatus(
      String sessionId, String assignmentId, WebWorkerStatus status) async {
    reportedStatus = status;
  }

  @override
  Future<void> sendFollowUp(String sessionId, String message) async {}
}

void main() {
  test('declares the web AI Worker as private subscription-backed v4', () {
    expect(webAiWorkerManifest['workerId'], 'conclave.web-ai');
    expect(webAiWorkerManifest['protocolVersion'], '4.0');
    expect(webAiWorkerManifest['credentialSharingPolicy'], 'private_only');
    expect(webAiWorkerManifest['sessionModes'], contains('reuse_session'));
    expect(webAiWorkerManifest['concurrencyModel'], isA<Map>());
  });

  test('completes a v4 assignment through a leased web Worker', () async {
    final relay = FakeRelay();
    final worker = WebAiWorker(relay);
    final session = await worker.start(
      'chatgpt-web',
      credentialProfileId: 'profile-a',
      assignmentId: 'assignment-1',
    );
    expect(session.status, WebWorkerStatus.waiting);
    expect((await worker.receiveTask(session))['taskId'], 'task-1');
    expect((await worker.submit(session, {'summary': 'candidate'}))['accepted'],
        true);
    expect(session.status, WebWorkerStatus.completed);
    expect(relay.lastProfile, 'profile-a');
    expect(relay.lastAssignment, 'assignment-1');
  });

  test('keeps separate credential profiles in separate sessions', () async {
    final relay = FakeRelay();
    final worker = WebAiWorker(relay);
    final first = await worker.start('chatgpt-web',
        credentialProfileId: 'profile-a', assignmentId: 'assignment-a');
    final second = await worker.start('chatgpt-web',
        credentialProfileId: 'profile-b', assignmentId: 'assignment-b');
    expect(first.sessionId, isNot(second.sessionId));
    expect(first.credentialProfileId, isNot(second.credentialProfileId));
  });

  test('supports reconnect and waiting-for-user status', () async {
    final relay = FakeRelay();
    relay.waitingForUser = true;
    final worker = WebAiWorker(relay);
    final session = await worker.start('chatgpt-web',
        credentialProfileId: 'profile-a', assignmentId: 'assignment-a');
    await worker.reconnect(session);
    expect(session.status, WebWorkerStatus.waiting);
    await worker.reportStatus(session, WebWorkerStatus.waitingForUser);
    expect(relay.reportedStatus, WebWorkerStatus.waitingForUser);
    expect(session.status, WebWorkerStatus.waitingForUser);
  });

  test('surfaces subscription quota state from the relay', () async {
    final relay = FakeRelay()..quotaExceeded = true;
    final session = await WebAiWorker(relay).start('chatgpt-web',
        credentialProfileId: 'profile-a', assignmentId: 'assignment-a');
    expect(session.status, WebWorkerStatus.quotaExceeded);
  });

  test('falls back to another provider when the first is unavailable',
      () async {
    final relay = FakeRelay();
    final session = await WebAiWorker(relay).start(
      'unavailable',
      credentialProfileId: 'profile-a',
      assignmentId: 'assignment-a',
      fallbackProviders: ['chatgpt-web'],
    );
    expect(session.provider, 'chatgpt-web');
  });

  test('rejects expired sessions before relay submission', () async {
    final session = WebWorkerSession(
      sessionId: 'expired',
      provider: 'claude-web',
      credentialProfileId: 'profile-a',
      assignmentId: 'assignment-a',
      leaseExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    expect(
        () => WebAiWorker(FakeRelay()).submit(session, {}), throwsStateError);
    expect(session.status, WebWorkerStatus.expired);
  });
}
