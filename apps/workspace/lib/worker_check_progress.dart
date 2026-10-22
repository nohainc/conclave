/// Service-owned, transient readiness evidence projected over local IPC.
/// Profile resolution and the combined CLI probe are real execution boundaries;
/// the UI must not invent provider-specific sub-tests or percentages.
enum WorkerCheckPhase { profile, probe, save }

enum WorkerCheckOutcome { running, passed, failed }

/// One Engine check reported by a completed readiness probe, such as the CLI
/// version, model list, Profile-defined command/config check, or account check.
/// Workspace displays exactly these returned checks; it does not repeat Profile
/// Lab's schema-validation or event-replay authoring tests.
class WorkerCheckStep {
  const WorkerCheckStep({
    required this.code,
    required this.status,
    required this.message,
  });

  final String code;

  /// `passed`, `warning`, `failed`, or `skipped`.
  final String status;
  final String message;

  Map<String, Object?> toJson() =>
      {'code': code, 'status': status, 'message': message};

  static WorkerCheckStep? fromJson(Object? value) {
    if (value is! Map ||
        value['code'] is! String ||
        value['status'] is! String ||
        value['message'] is! String) {
      return null;
    }
    return WorkerCheckStep(
      code: value['code'] as String,
      status: value['status'] as String,
      message: value['message'] as String,
    );
  }
}

class WorkerCheckProgress {
  const WorkerCheckProgress({
    required this.mode,
    required this.phase,
    required this.outcome,
    required this.startedAt,
    this.completedAt,
    this.issueCode,
    this.steps = const [],
  });

  final String mode;
  final WorkerCheckPhase phase;
  final WorkerCheckOutcome outcome;
  final String startedAt;
  final String? completedAt;
  final String? issueCode;

  /// Engine checks from the completed probe; empty while running.
  final List<WorkerCheckStep> steps;

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'mode': mode,
        'phase': phase.name,
        'outcome': outcome.name,
        'startedAt': startedAt,
        if (completedAt != null) 'completedAt': completedAt,
        if (issueCode != null) 'issueCode': issueCode,
        if (steps.isNotEmpty)
          'steps': [for (final step in steps) step.toJson()],
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
      steps: [
        if (value['steps'] case final List steps)
          for (final step in steps.map(WorkerCheckStep.fromJson))
            if (step != null) step,
      ],
    );
  }
}
