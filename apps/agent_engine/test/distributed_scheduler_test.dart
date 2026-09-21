import 'package:conclave_agent_engine/distributed_scheduler.dart';
import 'package:test/test.dart';

void main() {
  const workers = [
    WorkerCandidate(
        workerId: 'worker-a',
        agentId: 'agent-a',
        capabilities: {'research'},
        cost: 2),
    WorkerCandidate(
        workerId: 'worker-b',
        agentId: 'agent-b',
        capabilities: {'research'},
        cost: 3),
    WorkerCandidate(
        workerId: 'offline',
        agentId: 'agent-c',
        capabilities: {'research'},
        online: false),
  ];

  test('runs independent candidates in parallel and excludes offline workers',
      () async {
    final results = await DistributedScheduler().execute(
      workers: workers,
      requiredCapabilities: {'research'},
      mode: SchedulingMode.parallel,
      executor: (worker) async => worker.workerId,
    );
    expect(results.map((result) => result.output),
        containsAll(['worker-a', 'worker-b']));
    expect(
        results,
        everyElement(
            predicate<WorkerCandidateResult>((result) => result.succeeded)));
  });

  test('records a failed candidate so orchestration can fall back', () async {
    final results = await DistributedScheduler().execute(
      workers: workers,
      requiredCapabilities: {'research'},
      mode: SchedulingMode.parallel,
      executor: (worker) async {
        if (worker.workerId == 'worker-a') throw StateError('disconnected');
        return 'fallback';
      },
    );
    expect(
        results
            .singleWhere((result) => result.worker.workerId == 'worker-a')
            .succeeded,
        isFalse);
    expect(
        results
            .singleWhere((result) => result.worker.workerId == 'worker-b')
            .output,
        'fallback');
  });
}
