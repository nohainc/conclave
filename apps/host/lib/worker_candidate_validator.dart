import 'dart:io';

import 'worker_process_supervisor.dart';
import 'worker_release_verifier.dart';

abstract interface class WorkerCandidateHealthCheck {
  Future<void> validate(
    WorkerReleaseAdmission admission, {
    required Directory stateDirectory,
  });
}

/// Candidate admission delegates process ownership and protocol handling to
/// the same supervisor used for Worker assignments.
final class WorkerCandidateValidator implements WorkerCandidateHealthCheck {
  WorkerCandidateValidator({
    WorkerProcessSupervisor? supervisor,
    this.timeout = const Duration(seconds: 15),
  }) : _supervisor = supervisor ?? WorkerProcessSupervisor();

  final WorkerProcessSupervisor _supervisor;
  final Duration timeout;

  @override
  Future<void> validate(
    WorkerReleaseAdmission admission, {
    required Directory stateDirectory,
  }) async {
    try {
      await _supervisor.validateCandidate(
        admission,
        stateDirectory: stateDirectory,
        timeout: timeout,
      );
    } on WorkerProcessFailure catch (failure) {
      throw WorkerCandidateValidationFailure(
        issueCode: failure.issueCode,
        safeDiagnostic: failure.safeDiagnostic,
      );
    }
  }
}

final class WorkerCandidateValidationFailure implements Exception {
  const WorkerCandidateValidationFailure({
    required this.issueCode,
    required this.safeDiagnostic,
  });

  final String issueCode;
  final String safeDiagnostic;

  @override
  String toString() => 'WorkerCandidateValidationFailure($issueCode)';
}
