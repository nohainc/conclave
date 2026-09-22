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

  test('synthesizes candidate outputs through an explicit policy hook',
      () async {
    final results = await DistributedScheduler().execute(
      workers: workers,
      requiredCapabilities: {'research'},
      mode: SchedulingMode.synthesize,
      executor: (worker) async => worker.workerId,
      synthesize: (candidates) async => candidates
          .where((candidate) => candidate.succeeded)
          .map((candidate) => candidate.output)
          .join(','),
    );
    expect(results.last.worker.workerId, 'synthesizer');
    expect(results.last.output, 'worker-a,worker-b');
  });

  test('compare-and-select returns the policy-selected candidate', () async {
    final results = await DistributedScheduler().execute(
      workers: workers,
      requiredCapabilities: {'research'},
      mode: SchedulingMode.compareAndSelect,
      executor: (worker) async => worker.workerId,
      select: (candidates) async => candidates.last,
    );
    expect(results, hasLength(1));
    expect(results.single.output, 'worker-b');
  });

  test('competitive implementation uses distinct workspaces', () async {
    const candidates = [
      WorkerCandidate(
        workerId: 'a',
        agentId: 'agent-a',
        workspaceKey: 'workspace-a',
        capabilities: {'code'},
      ),
      WorkerCandidate(
        workerId: 'a-review',
        agentId: 'agent-a',
        workspaceKey: 'workspace-a',
        capabilities: {'code'},
      ),
      WorkerCandidate(
        workerId: 'b',
        agentId: 'agent-b',
        workspaceKey: 'workspace-b',
        capabilities: {'code'},
      ),
    ];
    final results = await DistributedScheduler().execute(
      workers: candidates,
      requiredCapabilities: {'code'},
      mode: SchedulingMode.competitiveImplementation,
      executor: (worker) async => worker.workerId,
      maxCandidates: 3,
    );
    expect(results.map((result) => result.output), containsAll(['a', 'b']));
    expect(results, hasLength(2));
  });

  test('compare-and-select can require provider independence', () async {
    const candidates = [
      WorkerCandidate(
        workerId: 'provider-a-1',
        agentId: 'agent-a',
        independenceKey: 'provider-a',
        capabilities: {'research'},
      ),
      WorkerCandidate(
        workerId: 'provider-a-2',
        agentId: 'agent-b',
        independenceKey: 'provider-a',
        capabilities: {'research'},
      ),
      WorkerCandidate(
        workerId: 'provider-b',
        agentId: 'agent-c',
        independenceKey: 'provider-b',
        capabilities: {'research'},
      ),
    ];
    final results = await DistributedScheduler().execute(
      workers: candidates,
      requiredCapabilities: {'research'},
      mode: SchedulingMode.compareAndSelect,
      maxCandidates: 3,
      requireIndependent: true,
      select: (candidates) async => candidates.last,
      executor: (worker) async => worker.workerId,
    );
    expect(results, hasLength(1));
    expect(results.single.output, 'provider-b');
  });

  test('stops candidate selection at the total cost budget', () async {
    final results = await DistributedScheduler().execute(
      workers: workers,
      requiredCapabilities: {'research'},
      mode: SchedulingMode.parallel,
      maxCandidates: 3,
      maxTotalCost: 4,
      executor: (worker) async => worker.workerId,
    );
    expect(results.map((result) => result.output), ['worker-a']);
  });

  test('requires a selector for compare-and-select policy', () async {
    expect(
      () => DistributedScheduler().execute(
        workers: workers,
        requiredCapabilities: {'research'},
        mode: SchedulingMode.compareAndSelect,
        executor: (worker) async => worker.workerId,
      ),
      throwsStateError,
    );
  });
}
