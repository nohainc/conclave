import 'package:conclave_agent_engine/web_ai_worker.dart';
import 'package:test/test.dart';

class FakeRelay implements WebWorkerRelay {
  @override
  Future<Map<String, Object?>> createSession(String provider) async => {
        'sessionId': 'session-1',
        'leaseExpiresAt':
            DateTime.now().add(const Duration(minutes: 1)).toIso8601String(),
      };
  @override
  Future<Map<String, Object?>> getContext(String sessionId) async =>
      {'taskId': 'task-1'};
  @override
  Future<Map<String, Object?>> submitResult(
          String sessionId, Map<String, Object?> result) async =>
      {'accepted': true};
  @override
  Future<void> sendFollowUp(String sessionId, String message) async {}
}

void main() {
  test('completes a leased web-worker candidate flow', () async {
    final worker = WebAiWorker(FakeRelay());
    final session = await worker.start('chatgpt-web');
    expect(session.status, WebWorkerStatus.waiting);
    expect((await worker.receiveTask(session))['taskId'], 'task-1');
    expect((await worker.submit(session, {'summary': 'candidate'}))['accepted'],
        true);
    expect(session.status, WebWorkerStatus.completed);
  });

  test('rejects expired sessions before relay submission', () async {
    final session = WebWorkerSession(
        sessionId: 'expired',
        provider: 'claude-web',
        leaseExpiresAt: DateTime.now().subtract(const Duration(seconds: 1)));
    expect(
        () => WebAiWorker(FakeRelay()).submit(session, {}), throwsStateError);
    expect(session.status, WebWorkerStatus.expired);
  });
}
