enum SchedulingMode {
  single,
  parallel,
  synthesize,
  compareAndSelect,
  competitiveImplementation,
}

class WorkerCandidate {
  const WorkerCandidate(
      {required this.workerId,
      required this.agentId,
      required this.capabilities,
      this.online = true,
      this.cost = 0,
      String? workspaceKey,
      String? independenceKey,
      this.billingMode = 'unknown'})
      : workspaceKey = workspaceKey ?? workerId,
        independenceKey = independenceKey ?? workerId;
  final String workerId;
  final String agentId;
  final Set<String> capabilities;
  final bool online;
  final int cost;
  final String workspaceKey;
  final String independenceKey;
  final String billingMode;
}

class WorkerCandidateResult {
  const WorkerCandidateResult(
      {required this.worker, required this.output, this.error});
  final WorkerCandidate worker;
  final Object? output;
  final Object? error;
  bool get succeeded => error == null;
}

typedef AssignmentRunner = Future<Object?> Function(WorkerCandidate worker);
typedef CandidateSynthesizer = Future<Object?> Function(
    List<WorkerCandidateResult> candidates);
typedef CandidateSelector = Future<WorkerCandidateResult> Function(
    List<WorkerCandidateResult> candidates);

class DistributedScheduler {
  Future<List<WorkerCandidateResult>> execute({
    required Iterable<WorkerCandidate> workers,
    required Set<String> requiredCapabilities,
    required AssignmentRunner executor,
    SchedulingMode mode = SchedulingMode.parallel,
    int maxCandidates = 2,
    int maxCost = 100,
    int maxTotalCost = 100,
    CandidateSynthesizer? synthesize,
    CandidateSelector? select,
    bool requireIndependent = false,
  }) async {
    if (maxCandidates <= 0 || maxCost < 0 || maxTotalCost < 0) {
      throw ArgumentError('scheduler limits must be non-negative and usable');
    }
    if (mode == SchedulingMode.compareAndSelect && select == null) {
      throw StateError('compareAndSelect mode requires a selector');
    }
    var eligible = workers
        .where((worker) =>
            worker.online &&
            requiredCapabilities.every(worker.capabilities.contains))
        .where((worker) => worker.cost <= maxCost)
        .toList();
    if (mode == SchedulingMode.competitiveImplementation) {
      final workspaces = <String>{};
      eligible = eligible
          .where((worker) => workspaces.add(worker.workspaceKey))
          .toList();
    }
    if (requireIndependent || mode == SchedulingMode.compareAndSelect) {
      final independenceKeys = <String>{};
      eligible = eligible
          .where((worker) => independenceKeys.add(worker.independenceKey))
          .toList();
    }
    final selected = <WorkerCandidate>[];
    var totalCost = 0;
    for (final worker in eligible) {
      if (selected.length >=
          (mode == SchedulingMode.single ? 1 : maxCandidates)) {
        break;
      }
      if (totalCost + worker.cost > maxTotalCost) continue;
      selected.add(worker);
      totalCost += worker.cost;
    }
    eligible = selected;
    if (eligible.isEmpty) throw StateError('no eligible online Worker');
    if (mode == SchedulingMode.single) {
      return [await _run(eligible.first, executor)];
    }
    final results = await Future.wait(
      eligible.map((worker) => _run(worker, executor)),
    );
    if (mode == SchedulingMode.synthesize) {
      final synthesizer = synthesize;
      if (synthesizer == null) {
        throw StateError('synthesize mode requires a synthesizer');
      }
      final output = await synthesizer(results);
      return [
        ...results,
        WorkerCandidateResult(
          worker: WorkerCandidate(
            workerId: 'synthesizer',
            agentId: 'scheduler',
            capabilities: const {},
          ),
          output: output,
        ),
      ];
    }
    if (mode == SchedulingMode.compareAndSelect) {
      return [await select!(results)];
    }
    return results;
  }

  Future<WorkerCandidateResult> _run(
      WorkerCandidate worker, AssignmentRunner executor) async {
    try {
      return WorkerCandidateResult(
          worker: worker, output: await executor(worker));
    } on Object catch (error) {
      return WorkerCandidateResult(worker: worker, output: null, error: error);
    }
  }
}
