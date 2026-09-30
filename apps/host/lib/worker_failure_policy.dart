import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'configured_worker_registry.dart';
import 'worker_process_supervisor.dart';
import 'worker_version_store.dart';

/// Local, version-scoped history for failures owned by a Worker release.
final class WorkerRuntimeFailureState {
  const WorkerRuntimeFailureState({
    required this.workerVersion,
    required this.consecutiveFailureCount,
    required this.lastIssueCode,
    required this.lastFailureKind,
    required this.needsAttention,
    this.rollbackSuggestedVersion,
  });

  final String workerVersion;
  final int consecutiveFailureCount;
  final String lastIssueCode;
  final WorkerRuntimeFailureKind lastFailureKind;
  final bool needsAttention;
  final String? rollbackSuggestedVersion;

  factory WorkerRuntimeFailureState.fromJson(Map<String, Object?> json) =>
      WorkerRuntimeFailureState(
        workerVersion: json['workerVersion']! as String,
        consecutiveFailureCount: json['consecutiveFailureCount']! as int,
        lastIssueCode: json['lastIssueCode']! as String,
        lastFailureKind: WorkerRuntimeFailureKind.values.firstWhere(
          (kind) => kind.name == json['lastFailureKind'],
        ),
        needsAttention: json['needsAttention']! as bool,
        rollbackSuggestedVersion: json['rollbackSuggestedVersion'] as String?,
      );

  Map<String, Object?> toJson() => {
        'schemaVersion': 1,
        'workerVersion': workerVersion,
        'consecutiveFailureCount': consecutiveFailureCount,
        'lastIssueCode': lastIssueCode,
        'lastFailureKind': lastFailureKind.name,
        'needsAttention': needsAttention,
        if (rollbackSuggestedVersion != null)
          'rollbackSuggestedVersion': rollbackSuggestedVersion,
      };
}

/// A quarantined release is prevented from taking another assignment.
final class WorkerReleaseNeedsAttention implements Exception {
  const WorkerReleaseNeedsAttention(this.state);
  final WorkerRuntimeFailureState state;

  @override
  String toString() => 'WorkerReleaseNeedsAttention';
}

/// Applies a bounded retry and crash-loop threshold to Worker assignments.
/// Failure state lives alongside Worker state and is independent of releases.
final class WorkerFailurePolicy {
  WorkerFailurePolicy({
    required this.versionStore,
    this.registry,
    this.failureThreshold = 3,
    this.maxAutomaticRetries = 1,
  }) {
    if (failureThreshold < 1 ||
        maxAutomaticRetries < 0 ||
        maxAutomaticRetries > 1) {
      throw ArgumentError('Invalid Worker failure policy bounds');
    }
  }

  final WorkerVersionStore versionStore;
  final LocalConfiguredWorkerRegistry? registry;
  final int failureThreshold;
  final int maxAutomaticRetries;
  final Map<String, Future<void>> _writeTails = {};

  File _stateFile(String workerTypeId) => File(
        '${versionStore.stateDirectory(workerTypeId).path}'
        '${Platform.pathSeparator}runtime-failure-state.json',
      );

  Future<WorkerRuntimeFailureState?> readState(String workerTypeId) async {
    final file = _stateFile(workerTypeId);
    if (!await file.exists()) return null;
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map<String, Object?> || value['schemaVersion'] != 1) {
        return null;
      }
      return WorkerRuntimeFailureState.fromJson(value);
    } on Object {
      // A damaged local diagnostic must not prevent Worker recovery.
      return null;
    }
  }

  Future<T> run<T>({
    required String workerTypeId,
    required String workerVersion,
    required Future<T> Function() attempt,
  }) async {
    final prior = await readState(workerTypeId);
    if (prior != null &&
        prior.workerVersion == workerVersion &&
        prior.needsAttention) {
      throw WorkerReleaseNeedsAttention(prior);
    }

    var retries = 0;
    while (true) {
      try {
        final result = await attempt();
        await _clearFailure(workerTypeId, workerVersion);
        return result;
      } on WorkerProcessFailure catch (failure) {
        if (!failure.isWorkerReleaseFailure) rethrow;
        if (failure.retrySafe && retries < maxAutomaticRetries) {
          retries++;
          continue;
        }
        final state = await _recordFailure(
          workerTypeId,
          workerVersion,
          failure,
        );
        if (state.needsAttention) throw WorkerReleaseNeedsAttention(state);
        rethrow;
      }
    }
  }

  Future<WorkerRuntimeFailureState> _recordFailure(
    String workerTypeId,
    String workerVersion,
    WorkerProcessFailure failure,
  ) async {
    late WorkerRuntimeFailureState state;
    await _locked(workerTypeId, () async {
      final prior = await readState(workerTypeId);
      final count = prior?.workerVersion == workerVersion
          ? prior!.consecutiveFailureCount + 1
          : 1;
      final release = await versionStore.releaseState(workerTypeId);
      final lkg = release.lastKnownGoodVersion;
      state = WorkerRuntimeFailureState(
        workerVersion: workerVersion,
        consecutiveFailureCount: count,
        lastIssueCode: failure.issueCode,
        lastFailureKind: failure.failureKind,
        needsAttention: count >= failureThreshold,
        rollbackSuggestedVersion:
            lkg != null && lkg != workerVersion ? lkg : null,
      );
      await versionStore.stateDirectory(workerTypeId).create(recursive: true);
      await _stateFile(workerTypeId).writeAsString(
        const JsonEncoder.withIndent('  ').convert(state.toJson()),
        flush: true,
      );
    });
    if (state.needsAttention) await _markRegistryNeedsAttention(workerTypeId);
    return state;
  }

  Future<void> _clearFailure(String workerTypeId, String workerVersion) async {
    await _locked(workerTypeId, () async {
      final state = await readState(workerTypeId);
      if (state?.workerVersion == workerVersion) {
        final file = _stateFile(workerTypeId);
        if (await file.exists()) await file.delete();
      }
    });
    await _clearRegistryIssue(workerTypeId);
  }

  Future<void> _markRegistryNeedsAttention(String workerTypeId) async {
    final localRegistry = registry;
    if (localRegistry == null) return;
    final workers = await localRegistry.list();
    for (final worker in workers.where((w) => w.workerTypeId == workerTypeId)) {
      await localRegistry.update(
        worker.id,
        (current) => current.copyWith(
          status: LocalWorkerStatus.needsAttention,
          readinessState: WorkerReadinessState.runtimeUnavailable,
          readinessIssueCode: 'worker_crash_loop',
        ),
      );
    }
  }

  Future<void> _clearRegistryIssue(String workerTypeId) async {
    final localRegistry = registry;
    if (localRegistry == null) return;
    final workers = await localRegistry.list();
    for (final worker in workers.where(
      (w) =>
          w.workerTypeId == workerTypeId &&
          w.readinessIssueCode == 'worker_crash_loop',
    )) {
      await localRegistry.update(
        worker.id,
        (current) => current.copyWith(
          status: current.activationState == LocalWorkerActivationState.disabled
              ? LocalWorkerStatus.disabled
              : LocalWorkerStatus.ready,
          readinessState: WorkerReadinessState.notProbed,
          clearReadinessIssueCode: true,
        ),
      );
    }
  }

  Future<void> _locked(String key, Future<void> Function() action) async {
    final previous = _writeTails[key] ?? Future<void>.value();
    final release = Completer<void>();
    _writeTails[key] = release.future;
    await previous;
    try {
      await action();
    } finally {
      release.complete();
      if (identical(_writeTails[key], release.future)) _writeTails.remove(key);
    }
  }
}
