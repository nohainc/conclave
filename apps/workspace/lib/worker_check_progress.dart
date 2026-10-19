/// Service-owned, transient readiness evidence projected over local IPC.
/// Profile resolution and the combined CLI probe are real execution boundaries;
/// the UI must not invent provider-specific sub-tests or percentages.
enum WorkerCheckPhase { profile, probe, save }

enum WorkerCheckOutcome { running, passed, failed }

class WorkerCheckProgress {
  const WorkerCheckProgress({
    required this.mode,
    required this.phase,
    required this.outcome,
    required this.startedAt,
    this.completedAt,
    this.issueCode,
  });

  final String mode;
  final WorkerCheckPhase phase;
  final WorkerCheckOutcome outcome;
  final String startedAt;
  final String? completedAt;
  final String? issueCode;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'mode': mode,
        'phase': phase.name,
        'outcome': outcome.name,
        'startedAt': startedAt,
        if (completedAt != null) 'completedAt': completedAt,
        if (issueCode != null) 'issueCode': issueCode,
      };

  static WorkerCheckProgress? fromJson(Object? value) {
    if (value is! Map || value['schemaVersion'] != 1) return null;
    final phase = WorkerCheckPhase.values
        .where((phase) => phase.name == value['phase'])
        .firstOrNull;
    final outcome = WorkerCheckOutcome.values
        .where((outcome) => outcome.name == value['outcome'])
        .firstOrNull;
    if (phase == null ||
        outcome == null ||
        value['startedAt'] is! String ||
        !const ['live', 'passive'].contains(value['mode'])) {
      return null;
    }
    return WorkerCheckProgress(
      mode: value['mode'] as String,
      phase: phase,
      outcome: outcome,
      startedAt: value['startedAt'] as String,
      completedAt: value['completedAt'] as String?,
      issueCode: value['issueCode'] as String?,
    );
  }
}
