enum SchedulingMode { single, parallel, compareAndSelect }

class WorkerCandidate {
  const WorkerCandidate(
      {required this.workerId,
      required this.agentId,
      required this.capabilities,
      this.online = true,
      this.cost = 0});
  final String workerId;
  final String agentId;
  final Set<String> capabilities;
  final bool online;
  final int cost;
}

class WorkerCandidateResult {
  const WorkerCandidateResult(
      {required this.worker, required this.output, this.error});
  final WorkerCandidate worker;
  final Object? output;
  final Object? error;
  bool get succeeded => error == null;
}

typedef WorkerExecutor = Future<Object?> Function(WorkerCandidate worker);

class DistributedScheduler {
  Future<List<WorkerCandidateResult>> execute({
    required Iterable<WorkerCandidate> workers,
    required Set<String> requiredCapabilities,
    required WorkerExecutor executor,
    SchedulingMode mode = SchedulingMode.parallel,
    int maxCandidates = 2,
    int maxCost = 100,
  }) async {
    final eligible = workers
        .where((worker) =>
            worker.online &&
            requiredCapabilities.every(worker.capabilities.contains))
        .where((worker) => worker.cost <= maxCost)
        .take(mode == SchedulingMode.single ? 1 : maxCandidates)
        .toList();
    if (eligible.isEmpty) throw StateError('no eligible online Worker');
    if (mode == SchedulingMode.single) {
      return [await _run(eligible.first, executor)];
    }
    return Future.wait(eligible.map((worker) => _run(worker, executor)));
  }

  Future<WorkerCandidateResult> _run(
      WorkerCandidate worker, WorkerExecutor executor) async {
    try {
      return WorkerCandidateResult(
          worker: worker, output: await executor(worker));
    } on Object catch (error) {
      return WorkerCandidateResult(worker: worker, output: null, error: error);
    }
  }
}
