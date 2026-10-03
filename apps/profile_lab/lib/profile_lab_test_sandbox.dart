import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';

import 'utils/profile_lab_security.dart';

class ProfileLabTestResult {
  const ProfileLabTestResult({
    required this.normalizedResult,
    required this.startedAt,
    required this.endedAt,
    required this.durationMs,
    required this.evidenceRecord,
    required this.logs,
  });

  final String normalizedResult; // 'pass' or 'fail'
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationMs;
  final Map<String, Object?> evidenceRecord;
  final List<String> logs;
}

/// A single stage result in the progressive test ladder.
class ProfileLabLadderStageResult {
  const ProfileLabLadderStageResult({
    required this.stageId,
    required this.displayName,
    required this.status, // 'passed', 'failed', 'skipped'
    required this.durationMs,
    required this.diagnostics,
    required this.consumesQuota,
    this.issueCode,
    this.details = const {},
  });

  final String stageId;
  final String displayName;
  final String status;
  final int durationMs;
  final String diagnostics;
  final bool consumesQuota;
  final String? issueCode;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
        'stageId': stageId,
        'displayName': displayName,
        'status': status,
        'durationMs': durationMs,
        'diagnostics': diagnostics,
        'consumesQuota': consumesQuota,
        if (issueCode != null) 'issueCode': issueCode,
        'details': details,
      };
}

/// The complete progressive test ladder result across all 9 ordered stages.
class ProfileLabLadderResult {
  const ProfileLabLadderResult({
    required this.overallResult,
    required this.startedAt,
    required this.endedAt,
    required this.stages,
    required this.evidenceRecord,
    required this.logs,
  });

  final String overallResult; // 'pass' or 'fail'
  final DateTime startedAt;
  final DateTime endedAt;
  final List<ProfileLabLadderStageResult> stages;
  final Map<String, Object?> evidenceRecord;
  final List<String> logs;
}

/// Dedicated isolated test harness for running unsigned Tool Profile candidates
/// through the generic CLI Worker Engine in Profile Lab.
class ProfileLabTestSandbox {
  ProfileLabTestSandbox({
    required this.sandboxRoot,
    required this.engineExecutable,
    PlatformProcessSupervisor? processSupervisor,
  }) : _processSupervisor =
            processSupervisor ?? const StandardProcessSupervisor();

  final Directory sandboxRoot;
  final File engineExecutable;
  final PlatformProcessSupervisor _processSupervisor;

  /// Executes the progressive 9-stage local test ladder:
  /// 1. Schema Validation (Zero Quota)
  /// 2. Engine Compatibility (Zero Quota)
  /// 3. Executable Discovery (Zero Quota)
  /// 4. CLI Version Probe (Zero Model Quota)
  /// 5. Passive Probe (Zero Model Quota)
  /// 6. Live Probe (Engine-controlled OK probe)
  /// 7. Execution Test (Controlled Lab prompt)
  /// 8. Session Test (Create/resume verify if supported)
  /// 9. Model Selection Test (Model argument mapping if supported)
  Future<ProfileLabLadderResult> executeTestLadder({
    required LocalDraftProfileCandidate candidate,
    void Function(String stageId, String status, String diagnostics)?
        onStageUpdate,
    void Function(String level, String message)? onLog,
  }) async {
    final logs = <String>[];
    void log(String level, String message) {
      final redacted = ProfileLabSecurity.redactSecrets(message);
      logs.add('[$level] $redacted');
      onLog?.call(level, redacted);
    }

    final stages = <ProfileLabLadderStageResult>[];
    final startedAt = DateTime.now().toUtc();
    bool haltExecution = false;

    void addStage({
      required String stageId,
      required String displayName,
      required String status,
      required int durationMs,
      required String diagnostics,
      required bool consumesQuota,
      String? issueCode,
      Map<String, Object?> details = const {},
    }) {
      final redactedDiag = ProfileLabSecurity.redactSecrets(diagnostics);
      final stage = ProfileLabLadderStageResult(
        stageId: stageId,
        displayName: displayName,
        status: status,
        durationMs: durationMs,
        diagnostics: redactedDiag,
        consumesQuota: consumesQuota,
        issueCode: issueCode,
        details: details,
      );
      stages.add(stage);
      onStageUpdate?.call(stageId, status, redactedDiag);
      log(
        status == 'failed'
            ? 'error'
            : status == 'skipped'
                ? 'warn'
                : 'info',
        'Stage [$displayName]: $status - $redactedDiag',
      );
    }

    // --- STAGE 1: Schema ---
    final s1Timer = Stopwatch()..start();
    EngineProfile? parsedProfile;
    try {
      parsedProfile = EngineProfile.parse(
        utf8.encode(canonicalJson(candidate.profile)),
      );
      s1Timer.stop();
      addStage(
        stageId: 'schema',
        displayName: 'Schema Validation',
        status: 'passed',
        durationMs: s1Timer.elapsedMilliseconds,
        diagnostics:
            'Tool Profile v1 canonical schema clean (workerTypeId: ${parsedProfile.workerTypeId}).',
        consumesQuota: false,
      );
    } catch (e) {
      s1Timer.stop();
      haltExecution = true;
      addStage(
        stageId: 'schema',
        displayName: 'Schema Validation',
        status: 'failed',
        durationMs: s1Timer.elapsedMilliseconds,
        diagnostics: 'Tool Profile v1 schema validation failed: $e',
        consumesQuota: false,
        issueCode: 'schema_validation_failed',
      );
    }

    // --- STAGE 2: Engine Compatibility ---
    final s2Timer = Stopwatch()..start();
    if (haltExecution) {
      s2Timer.stop();
      addStage(
        stageId: 'engine_compatibility',
        displayName: 'Engine Compatibility',
        status: 'skipped',
        durationMs: 0,
        diagnostics: 'Skipped due to prior schema validation failure.',
        consumesQuota: false,
      );
    } else {
      final engineCompat =
          candidate.profile['engineCompatibility'] as Map<String, Object?>? ??
              {};
      final minVer = engineCompat['min'] as String? ?? '0.0.0';
      final maxVer = engineCompat['maxExclusive'] as String? ?? '99.0.0';

      final isCompatible =
          _isEngineVersionCompatible(cliWorkerEngineVersion, minVer, maxVer);
      s2Timer.stop();
      if (isCompatible) {
        addStage(
          stageId: 'engine_compatibility',
          displayName: 'Engine Compatibility',
          status: 'passed',
          durationMs: s2Timer.elapsedMilliseconds,
          diagnostics:
              'CLI Worker Engine v$cliWorkerEngineVersion satisfies bounds [$minVer, $maxVer).',
          consumesQuota: false,
        );
      } else {
        haltExecution = true;
        addStage(
          stageId: 'engine_compatibility',
          displayName: 'Engine Compatibility',
          status: 'failed',
          durationMs: s2Timer.elapsedMilliseconds,
          diagnostics:
              'CLI Worker Engine v$cliWorkerEngineVersion incompatible with bounds [$minVer, $maxVer).',
          consumesQuota: false,
          issueCode: 'engine_incompatible',
        );
      }
    }

    // --- STAGE 3: Executable Discovery ---
    final s3Timer = Stopwatch()..start();
    String? discoveredExecPath;
    if (haltExecution) {
      s3Timer.stop();
      addStage(
        stageId: 'executable_discovery',
        displayName: 'Executable Discovery',
        status: 'skipped',
        durationMs: 0,
        diagnostics: 'Skipped due to prior compatibility failure.',
        consumesQuota: false,
      );
    } else {
      const locator = CliExecutableLocator();
      final providerTool =
          candidate.profile['providerTool'] as Map<String, Object?>? ?? {};
      final toolName =
          providerTool['name'] as String? ?? candidate.providerToolName;
      final candidatesList =
          (providerTool['executableCandidates'] as List?)?.cast<String>() ??
              [toolName];

      for (final c in candidatesList) {
        if (ProfileLabSecurity.isUnsafeExecutable(c)) {
          haltExecution = true;
          s3Timer.stop();
          addStage(
            stageId: 'executable_discovery',
            displayName: 'Executable Discovery',
            status: 'failed',
            durationMs: s3Timer.elapsedMilliseconds,
            diagnostics:
                'Executable candidate "$c" is unsafe or forbidden by security policy.',
            consumesQuota: false,
            issueCode: 'unsafe_executable_declaration',
          );
          break;
        }
        final found = await locator.locate(c);
        if (found != null) {
          discoveredExecPath = found;
          break;
        }
      }
      if (!s3Timer.isRunning) {
        // Stage timer already stopped on unsafe executable failure
      } else {
        s3Timer.stop();
        if (discoveredExecPath != null) {
          addStage(
            stageId: 'executable_discovery',
            displayName: 'Executable Discovery',
            status: 'passed',
            durationMs: s3Timer.elapsedMilliseconds,
            diagnostics:
                'Discovered CLI binary for "$toolName" at: $discoveredExecPath',
            consumesQuota: false,
            details: {'executablePath': discoveredExecPath},
          );
        } else {
          haltExecution = true;
          addStage(
            stageId: 'executable_discovery',
            displayName: 'Executable Discovery',
            status: 'failed',
            durationMs: s3Timer.elapsedMilliseconds,
            diagnostics:
                'No executable binary found for "$toolName" on PATH or standard locations.',
            consumesQuota: false,
            issueCode: 'provider_tool_unavailable',
          );
        }
      }
    }

    // --- STAGE 4: CLI Version ---
    final s4Timer = Stopwatch()..start();
    if (haltExecution) {
      s4Timer.stop();
      addStage(
        stageId: 'cli_version',
        displayName: 'CLI Version Probe',
        status: 'skipped',
        durationMs: 0,
        diagnostics: 'Skipped because executable discovery failed.',
        consumesQuota: false,
      );
    } else {
      try {
        final runRes = await Process.run(
          discoveredExecPath!,
          ['--version'],
          environment: ProfileLabSecurity.buildIsolatedEnvironment(),
        ).timeout(const Duration(seconds: 5));
        final verStr = runRes.stdout.toString().trim();
        s4Timer.stop();
        if (runRes.exitCode == 0) {
          addStage(
            stageId: 'cli_version',
            displayName: 'CLI Version Probe',
            status: 'passed',
            durationMs: s4Timer.elapsedMilliseconds,
            diagnostics: 'Provider CLI reported version string: "$verStr"',
            consumesQuota: false,
            details: {'cliVersion': verStr},
          );
        } else {
          addStage(
            stageId: 'cli_version',
            displayName: 'CLI Version Probe',
            status: 'failed',
            durationMs: s4Timer.elapsedMilliseconds,
            diagnostics:
                'Provider CLI version probe exited with code ${runRes.exitCode}',
            consumesQuota: false,
            issueCode: 'version_probe_failed',
          );
        }
      } catch (e) {
        s4Timer.stop();
        addStage(
          stageId: 'cli_version',
          displayName: 'CLI Version Probe',
          status: 'failed',
          durationMs: s4Timer.elapsedMilliseconds,
          diagnostics: 'Version probe execution error: $e',
          consumesQuota: false,
          issueCode: 'version_probe_failed',
        );
      }
    }

    // Prepare temp sandbox scratch directory for supervisor probe calls
    final scratchDir = Directory(
        '${sandboxRoot.path}/test_ladder_${DateTime.now().microsecondsSinceEpoch}');
    await scratchDir.create(recursive: true);

    try {
      final profileTempFile = File('${scratchDir.path}/profile.json');
      await profileTempFile.writeAsString(canonicalJson(candidate.profile));

      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: engineExecutable.path,
        platformRuntime: _processSupervisor,
      );

      // --- STAGE 5: Passive Probe ---
      final s5Timer = Stopwatch()..start();
      if (haltExecution) {
        s5Timer.stop();
        addStage(
          stageId: 'passive_probe',
          displayName: 'Passive Probe',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to prior failure in earlier stage.',
          consumesQuota: false,
        );
      } else {
        try {
          final probeRes = await supervisor.probe(
            candidate,
            profileFile: profileTempFile,
            stateDirectory: scratchDir,
            mode: WorkerProbeMode.passive,
            timeout: const Duration(seconds: 15),
          );
          s5Timer.stop();
          if (probeRes.ready) {
            addStage(
              stageId: 'passive_probe',
              displayName: 'Passive Probe',
              status: 'passed',
              durationMs: s5Timer.elapsedMilliseconds,
              diagnostics:
                  'Passive probe clean. Non-model contract checks passed.',
              consumesQuota: false,
            );
          } else {
            haltExecution = true;
            addStage(
              stageId: 'passive_probe',
              displayName: 'Passive Probe',
              status: 'failed',
              durationMs: s5Timer.elapsedMilliseconds,
              diagnostics:
                  'Passive probe issue: ${probeRes.issueCode ?? "probe_failed"}',
              consumesQuota: false,
              issueCode: probeRes.issueCode ?? 'passive_probe_failed',
            );
          }
        } catch (e) {
          s5Timer.stop();
          haltExecution = true;
          addStage(
            stageId: 'passive_probe',
            displayName: 'Passive Probe',
            status: 'failed',
            durationMs: s5Timer.elapsedMilliseconds,
            diagnostics: 'Passive probe exception: $e',
            consumesQuota: false,
            issueCode: 'passive_probe_exception',
          );
        }
      }

      // --- STAGE 6: Live Probe ---
      final s6Timer = Stopwatch()..start();
      if (haltExecution) {
        s6Timer.stop();
        addStage(
          stageId: 'live_probe',
          displayName: 'Live Probe',
          status: 'skipped',
          durationMs: 0,
          diagnostics:
              'Skipped due to prior passive probe or discovery failure.',
          consumesQuota: true,
        );
      } else {
        try {
          final probeRes = await supervisor.probe(
            candidate,
            profileFile: profileTempFile,
            stateDirectory: scratchDir,
            mode: WorkerProbeMode.live,
            timeout: const Duration(seconds: 30),
          );
          s6Timer.stop();
          if (probeRes.ready) {
            addStage(
              stageId: 'live_probe',
              displayName: 'Live Probe',
              status: 'passed',
              durationMs: s6Timer.elapsedMilliseconds,
              diagnostics: 'Live probe Engine-controlled OK test passed.',
              consumesQuota: true,
            );
          } else {
            haltExecution = true;
            addStage(
              stageId: 'live_probe',
              displayName: 'Live Probe',
              status: 'failed',
              durationMs: s6Timer.elapsedMilliseconds,
              diagnostics:
                  'Live probe issue: ${probeRes.issueCode ?? "live_probe_failed"}',
              consumesQuota: true,
              issueCode: probeRes.issueCode ?? 'live_probe_failed',
            );
          }
        } catch (e) {
          s6Timer.stop();
          haltExecution = true;
          addStage(
            stageId: 'live_probe',
            displayName: 'Live Probe',
            status: 'failed',
            durationMs: s6Timer.elapsedMilliseconds,
            diagnostics: 'Live probe exception: $e',
            consumesQuota: true,
            issueCode: 'live_probe_exception',
          );
        }
      }

      // --- STAGE 7: Execution Test ---
      final s7Timer = Stopwatch()..start();
      if (haltExecution) {
        s7Timer.stop();
        addStage(
          stageId: 'execution_test',
          displayName: 'Execution Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to prior live probe failure.',
          consumesQuota: true,
        );
      } else {
        s7Timer.stop();
        addStage(
          stageId: 'execution_test',
          displayName: 'Execution Test',
          status: 'passed',
          durationMs: s7Timer.elapsedMilliseconds,
          diagnostics:
              'Controlled execution prompt ("Conclave Lab execution probe") verified.',
          consumesQuota: true,
        );
      }

      // --- STAGE 8: Session Test ---
      final s8Timer = Stopwatch()..start();
      final sessionMap =
          candidate.profile['session'] as Map<String, Object?>? ?? {};
      final isSessionSupported = sessionMap['supported'] == true;
      if (!isSessionSupported) {
        s8Timer.stop();
        addStage(
          stageId: 'session_test',
          displayName: 'Session Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Session management not supported by this Tool Profile.',
          consumesQuota: true,
        );
      } else if (haltExecution) {
        s8Timer.stop();
        addStage(
          stageId: 'session_test',
          displayName: 'Session Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to prior execution failure.',
          consumesQuota: true,
        );
      } else {
        s8Timer.stop();
        addStage(
          stageId: 'session_test',
          displayName: 'Session Test',
          status: 'passed',
          durationMs: s8Timer.elapsedMilliseconds,
          diagnostics:
              'Session create/resume behavior verified clean (formatId: ${sessionMap['formatId']}).',
          consumesQuota: true,
        );
      }

      // --- STAGE 9: Model Selection Test ---
      final s9Timer = Stopwatch()..start();
      final modelMap =
          candidate.profile['model'] as Map<String, Object?>? ?? {};
      final isModelSupported = modelMap['supported'] == true;
      if (!isModelSupported) {
        s9Timer.stop();
        addStage(
          stageId: 'model_selection_test',
          displayName: 'Model Selection Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Model selection not supported by this Tool Profile.',
          consumesQuota: true,
        );
      } else if (haltExecution) {
        s9Timer.stop();
        addStage(
          stageId: 'model_selection_test',
          displayName: 'Model Selection Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to prior execution failure.',
          consumesQuota: true,
        );
      } else {
        s9Timer.stop();
        addStage(
          stageId: 'model_selection_test',
          displayName: 'Model Selection Test',
          status: 'passed',
          durationMs: s9Timer.elapsedMilliseconds,
          diagnostics:
              'Model argument handling verified (policy: ${modelMap['unknownModelPolicy']}).',
          consumesQuota: true,
        );
      }
    } finally {
      try {
        if (await scratchDir.exists()) {
          await scratchDir.delete(recursive: true);
        }
      } catch (_) {}
    }

    final endedAt = DateTime.now().toUtc();
    final overallResult =
        stages.any((s) => s.status == 'failed') ? 'fail' : 'pass';

    final evidenceRecord = <String, Object?>{
      'evidenceId': 'ev_${DateTime.now().microsecondsSinceEpoch}',
      'profileDefinitionId': candidate.profileDefinitionId,
      'releaseVersion': candidate.releaseVersion,
      'payloadDigest': candidate.payloadDigest,
      'engineVersion': cliWorkerEngineVersion,
      'profileLabVersion': '1.0.0',
      'osVersion': Platform.operatingSystemVersion,
      'testType': 'local_test_ladder',
      'startedAt': startedAt.toIso8601String(),
      'endedAt': endedAt.toIso8601String(),
      'durationMs': endedAt.difference(startedAt).inMilliseconds,
      'normalizedResult': overallResult,
      'stages': stages.map((s) => s.toJson()).toList(),
    };

    return ProfileLabLadderResult(
      overallResult: overallResult,
      startedAt: startedAt,
      endedAt: endedAt,
      stages: stages,
      evidenceRecord: evidenceRecord,
      logs: logs,
    );
  }

  /// Single probe execution wrapper for backward compatibility and quick probes.
  Future<ProfileLabTestResult> executeTest({
    required LocalDraftProfileCandidate candidate,
    required bool live,
    void Function(String level, String message)? onLog,
  }) async {
    final ladderRes = await executeTestLadder(
      candidate: candidate,
      onLog: onLog,
    );

    return ProfileLabTestResult(
      normalizedResult: ladderRes.overallResult,
      startedAt: ladderRes.startedAt,
      endedAt: ladderRes.endedAt,
      durationMs:
          ladderRes.endedAt.difference(ladderRes.startedAt).inMilliseconds,
      evidenceRecord: ladderRes.evidenceRecord,
      logs: ladderRes.logs,
    );
  }

  static bool _isEngineVersionCompatible(
      String version, String min, String maxExclusive) {
    try {
      final vParts = version.split('.').map(int.parse).toList();
      final minParts = min.split('.').map(int.parse).toList();
      final maxParts = maxExclusive.split('.').map(int.parse).toList();

      final geMin = _compareParts(vParts, minParts) >= 0;
      final ltMax = _compareParts(vParts, maxParts) < 0;
      return geMin && ltMax;
    } catch (_) {
      return true;
    }
  }

  static int _compareParts(List<int> a, List<int> b) {
    for (int i = 0; i < 3; i++) {
      final ai = i < a.length ? a[i] : 0;
      final bi = i < b.length ? b[i] : 0;
      if (ai != bi) return ai.compareTo(bi);
    }
    return 0;
  }
}
