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
    required this.acceptanceEvidence,
    required this.logs,
  });

  final String normalizedResult; // 'pass' or 'fail'
  final DateTime startedAt;
  final DateTime endedAt;
  final int durationMs;
  final ToolProfileAcceptanceEvidence? acceptanceEvidence;
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

/// The complete progressive test ladder result across all 11 ordered stages.
class ProfileLabLadderResult {
  const ProfileLabLadderResult({
    required this.overallResult,
    required this.startedAt,
    required this.endedAt,
    required this.stages,
    required this.acceptanceEvidence,
    required this.logs,
  });

  final String overallResult; // 'pass' or 'fail'
  final DateTime startedAt;
  final DateTime endedAt;
  final List<ProfileLabLadderStageResult> stages;

  /// Exact Cloud acceptance contract, present only when every required
  /// applicable acceptance scenario was observed to pass against this candidate.
  final ToolProfileAcceptanceEvidence? acceptanceEvidence;
  final List<String> logs;
}

/// Profile Lab's direct representation of Cloud's qualification and acceptance
/// contract. Its serialized shape intentionally matches
/// ToolProfileAcceptanceEvidence in apps/cloud/src/tool-profile-validation.ts.
class ToolProfileAcceptanceEvidence {
  const ToolProfileAcceptanceEvidence({
    required this.profileDefinitionId,
    required this.releaseVersion,
    required this.profileDigest,
    required this.logicalWorkerTypeId,
    required this.engineVersion,
    required this.providerToolName,
    required this.providerToolVersion,
    required this.acceptedAt,
    required this.scenarios,
  });

  final String profileDefinitionId;
  final int releaseVersion;
  final String profileDigest;
  final String logicalWorkerTypeId;
  final String engineVersion;
  final String providerToolName;
  final String providerToolVersion;
  final String acceptedAt;
  final Map<String, String> scenarios;

  Map<String, Object?> toJson() => {
        'formatVersion': 2,
        'profileDefinitionId': profileDefinitionId,
        'releaseVersion': releaseVersion,
        'profileReleaseVersion': '$releaseVersion',
        'logicalWorkerTypeId': logicalWorkerTypeId,
        'profileDigest': profileDigest,
        'engineVersion': engineVersion,
        'providerToolName': providerToolName,
        'providerToolVersion': providerToolVersion,
        'acceptedAt': acceptedAt,
        'scenarios': scenarios,
      };

  static bool hasCloudContractShape(
    Map<String, Object?> json, {
    Map<String, Object?>? profile,
  }) {
    const fields = {
      'formatVersion',
      'profileDefinitionId',
      'releaseVersion',
      'profileReleaseVersion',
      'logicalWorkerTypeId',
      'profileDigest',
      'engineVersion',
      'providerToolName',
      'providerToolVersion',
      'acceptedAt',
      'scenarios',
    };
    final scenarios = json['scenarios'];
    return json.keys.toSet().containsAll(fields) &&
        fields.containsAll(json.keys) &&
        json['formatVersion'] == 2 &&
        json['profileDefinitionId'] is String &&
        json['releaseVersion'] is int &&
        json['profileReleaseVersion'] == '${json['releaseVersion']}' &&
        json['logicalWorkerTypeId'] is String &&
        json['profileDigest'] is String &&
        json['engineVersion'] is String &&
        json['providerToolName'] is String &&
        json['providerToolVersion'] is String &&
        json['acceptedAt'] is String &&
        DateTime.tryParse(json['acceptedAt'] as String) != null &&
        scenarios is Map &&
        scenarios.keys.toSet().containsAll(cloudAcceptanceScenarioNames) &&
        cloudAcceptanceScenarioNames.toSet().containsAll(scenarios.keys) &&
        scenarios.values.every(
          (result) => result == 'passed' || result == 'not_applicable',
        ) &&
        (profile == null ||
            _sameScenarioStatuses(
              scenarios.cast<String, Object?>(),
              cloudAcceptanceScenarioStatuses(profile),
            ));
  }

  static bool _sameScenarioStatuses(
    Map<String, Object?> actual,
    Map<String, String>? expected,
  ) =>
      expected != null &&
      expected.length == actual.length &&
      expected.entries.every((entry) => actual[entry.key] == entry.value);
}

Future<void> _deleteSandboxTreeWithoutFollowingLinks(
    Directory directory) async {
  await for (final entity in directory.list(followLinks: false)) {
    final type = await FileSystemEntity.type(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await Link(entity.path).delete();
    } else if (type == FileSystemEntityType.directory) {
      await _deleteSandboxTreeWithoutFollowingLinks(Directory(entity.path));
      await Directory(entity.path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(entity.path).delete();
    }
  }
}

const cloudAcceptanceScenarioNames = <String>[
  'passive_probe',
  'live_probe',
  'model_selection',
  'representative_workstream_write',
  'durable_session_start',
  'durable_session_resume',
  'cancellation',
  'timeout',
];

/// Derives the Cloud scenario status map from the candidate Tool Profile.
/// A null result means the Profile contradicts itself about durable sessions.
Map<String, String>? cloudAcceptanceScenarioStatuses(
  Map<String, Object?> profile,
) {
  final capabilities =
      (profile['capabilities'] as List?)?.whereType<String>().toSet() ??
          const <String>{};
  final session = profile['session'] as Map<String, Object?>? ?? const {};
  final model = profile['model'] as Map<String, Object?>? ?? const {};
  final hasDurableSessionCapability = capabilities.contains('durable_session');
  final sessionSupported = session['supported'] == true;
  if (hasDurableSessionCapability != sessionSupported) return null;

  return {
    'passive_probe': 'passed',
    'live_probe': 'passed',
    'model_selection': model['supported'] == true &&
            ((model['allowlist'] as List?)?.isNotEmpty ?? false)
        ? 'passed'
        : 'not_applicable',
    'representative_workstream_write':
        capabilities.contains('workstream_write') ? 'passed' : 'not_applicable',
    'durable_session_start':
        hasDurableSessionCapability ? 'passed' : 'not_applicable',
    'durable_session_resume':
        hasDurableSessionCapability ? 'passed' : 'not_applicable',
    'cancellation': 'passed',
    'timeout': 'passed',
  };
}

/// Dedicated isolated test harness for running unsigned Tool Profile candidates
/// through the generic CLI Worker Engine in Profile Lab.
class ProfileLabTestSandbox {
  ProfileLabTestSandbox({
    required this.sandboxRoot,
    required this.engineExecutable,
    PlatformProcessSupervisor? processSupervisor,
    this.environmentOverrides = const {},
  }) : _processSupervisor =
            processSupervisor ?? const StandardProcessSupervisor();

  final Directory sandboxRoot;
  final File engineExecutable;
  final PlatformProcessSupervisor _processSupervisor;
  final Map<String, String> environmentOverrides;
  CliWorkerEngineSupervisor? _activeSupervisor;
  String? _activeAssignmentId;

  /// Cancels the active Engine assignment, including the provider CLI process tree.
  Future<bool> cancelCurrentTest() async {
    final supervisor = _activeSupervisor;
    final assignmentId = _activeAssignmentId;
    if (supervisor == null || assignmentId == null) return false;
    return supervisor.cancel(assignmentId);
  }

  /// Runs a draft proposal through a trusted, signed Worker Profile. The
  /// unsigned Profile being edited is never used to invoke the model.
  Future<String> runTrustedModelProposal({
    required ToolProfileReleaseAdmission modelProfile,
    required String prompt,
    String? model,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (_activeSupervisor != null) {
      throw StateError('Another Profile Lab Engine operation is active.');
    }
    if (!modelProfile.isSigned) {
      throw StateError('AI proposal requires a signed Worker Profile.');
    }

    final configuredRoot = sandboxRoot.absolute;
    final rootType = await FileSystemEntity.type(
      configuredRoot.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) {
      throw FileSystemException(
          'Sandbox root is not a real directory', configuredRoot.path);
    }
    final canonicalRoot = await configuredRoot.resolveSymbolicLinks();
    final scratchDir = await Directory(canonicalRoot).createTemp('ai_draft_');
    final assignmentId =
        'profile-lab-ai-${DateTime.now().microsecondsSinceEpoch}';
    final supervisor = CliWorkerEngineSupervisor(
      engineExecutable: engineExecutable.path,
      platformRuntime: _processSupervisor,
      environmentOverrides: environmentOverrides,
    );
    _activeSupervisor = supervisor;
    _activeAssignmentId = assignmentId;
    try {
      final profileTempFile = File('${scratchDir.path}/profile.json');
      await profileTempFile.writeAsString(canonicalJson(modelProfile.profile));
      if (Platform.isMacOS || Platform.isLinux) {
        final chmod = await Process.run('chmod', ['600', profileTempFile.path]);
        if (chmod.exitCode != 0) {
          throw FileSystemException(
              'Could not restrict model Profile file permissions',
              profileTempFile.path);
        }
      }
      final result = await supervisor.execute(
        modelProfile,
        profileFile: profileTempFile,
        stateDirectory: scratchDir,
        workingDirectory: scratchDir,
        workerId: 'profile-lab-ai-${modelProfile.logicalWorkerTypeId}',
        maxConcurrentAssignments: 1,
        assignmentId: assignmentId,
        prompt: prompt,
        timeout: timeout,
        sessionPolicy: WorkerSessionPolicy.stateless,
        model: model,
        executionPolicy: WorkerExecutionPolicy.restricted,
      );
      return result.output;
    } finally {
      _activeSupervisor = null;
      _activeAssignmentId = null;
      await supervisor.shutdown();
      await _deleteSandboxTreeWithoutFollowingLinks(scratchDir);
      await scratchDir.delete();
    }
  }

  /// Executes the progressive local test ladder:
  /// 1. Schema Validation (Zero Quota)
  /// 2. Engine Compatibility (Zero Quota)
  /// 3. Executable Discovery (Zero Quota)
  /// 4. CLI Version Probe (Zero Model Quota)
  /// 5. Passive Probe (Zero Model Quota)
  /// 6. Live Probe (Engine-controlled OK probe)
  /// 7. Representative workstream write (real assignment and file verification)
  /// 8. Session Test (real create/resume assignments if supported)
  /// 9. Model Selection Test (real model-selected assignment if supported)
  /// 10. Cancellation Test (real assignment canceled through the Engine)
  /// 11. Timeout Test (real assignment with a bounded Engine deadline)
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
    final observedAcceptanceScenarios = <String, String>{};
    Map<String, String>? expectedAcceptanceScenarios;
    String? detectedProviderToolVersion;

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
      expectedAcceptanceScenarios =
          cloudAcceptanceScenarioStatuses(candidate.profile);
      if (expectedAcceptanceScenarios == null) {
        throw const FormatException(
          'durable_session capability does not match session.supported',
        );
      }
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
      final discovery =
          providerTool['discovery'] as Map<String, Object?>? ?? const {};
      final standardPaths =
          (discovery['standardLocations'] as List?)?.whereType<String>() ??
              const <String>[];
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
        final found = await locator.locate(
          c,
          environment: {...Platform.environment, ...environmentOverrides},
          standardPaths: standardPaths,
        );
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
        final providerTool =
            candidate.profile['providerTool'] as Map<String, Object?>? ?? {};
        final runRes = await Process.run(
          discoveredExecPath!,
          ['--version'],
          environment: ProfileLabSecurity.buildIsolatedEnvironment(),
        ).timeout(const Duration(seconds: 5));
        final versionProbe =
            providerTool['versionProbe'] as Map<String, Object?>? ?? {};
        final versionOutput = versionProbe['source'] == 'stderr'
            ? runRes.stderr.toString().trim()
            : runRes.stdout.toString().trim();
        s4Timer.stop();
        if (runRes.exitCode == 0) {
          final versionMatch = RegExp(
            r'(?<![0-9])(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?',
          ).firstMatch(versionOutput);
          detectedProviderToolVersion = versionMatch?.group(0);
          final supportedVersions =
              (providerTool['supportedVersions'] as List?) ?? const [];
          final detectedVersion = detectedProviderToolVersion;
          final isSupported = detectedVersion != null &&
              supportedVersions.any((range) {
                if (range is! Map) return false;
                final min = range['min'];
                final maxExclusive = range['maxExclusive'];
                if (min is! String || maxExclusive is! String) return false;
                final lower = _compareReleaseSemver(detectedVersion, min);
                final upper =
                    _compareReleaseSemver(detectedVersion, maxExclusive);
                return lower != null &&
                    upper != null &&
                    lower >= 0 &&
                    upper < 0;
              });
          if (isSupported) {
            addStage(
              stageId: 'cli_version',
              displayName: 'CLI Version Probe',
              status: 'passed',
              durationMs: s4Timer.elapsedMilliseconds,
              diagnostics:
                  'Provider CLI version $detectedProviderToolVersion is within a declared supported range.',
              consumesQuota: false,
              details: {'cliVersion': detectedProviderToolVersion},
            );
          } else {
            haltExecution = true;
            addStage(
              stageId: 'cli_version',
              displayName: 'CLI Version Probe',
              status: 'failed',
              durationMs: s4Timer.elapsedMilliseconds,
              diagnostics: detectedProviderToolVersion == null
                  ? 'Provider CLI version output did not contain a semantic version.'
                  : 'Provider CLI version $detectedProviderToolVersion is outside declared supported ranges.',
              consumesQuota: false,
              issueCode: 'provider_version_unsupported',
            );
          }
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
    final configuredRoot = sandboxRoot.absolute;
    final rootType = await FileSystemEntity.type(
      configuredRoot.path,
      followLinks: false,
    );
    if (rootType != FileSystemEntityType.directory) {
      throw FileSystemException(
          'Sandbox root is not a real directory', configuredRoot.path);
    }
    final canonicalRoot = await configuredRoot.resolveSymbolicLinks();
    final canonicalRootDirectory = Directory(canonicalRoot);
    final scratchDir = await canonicalRootDirectory.createTemp('test_ladder_');

    try {
      final profileTempFile = File('${scratchDir.path}/profile.json');
      await profileTempFile.writeAsString(canonicalJson(candidate.profile));

      final supervisor = CliWorkerEngineSupervisor(
        engineExecutable: engineExecutable.path,
        platformRuntime: _processSupervisor,
        environmentOverrides: environmentOverrides,
      );
      _activeSupervisor = supervisor;

      Future<WorkerResult> executeAssignment({
        required String label,
        required String prompt,
        Duration timeout = const Duration(seconds: 60),
        WorkerSessionPolicy sessionPolicy = WorkerSessionPolicy.stateless,
        String? sessionKey,
        String? model,
      }) {
        final assignmentId = 'lab-${label.replaceAll('_', '-')}-'
            '${DateTime.now().microsecondsSinceEpoch}';
        _activeAssignmentId = assignmentId;
        return supervisor
            .execute(
          candidate,
          profileFile: profileTempFile,
          stateDirectory: scratchDir,
          workingDirectory: scratchDir,
          workerId: 'profile-lab-${candidate.profileDefinitionId}',
          maxConcurrentAssignments: 1,
          assignmentId: assignmentId,
          prompt: prompt,
          timeout: timeout,
          sessionPolicy: sessionPolicy,
          sessionKey: sessionKey,
          model: model,
        )
            .whenComplete(() {
          if (_activeAssignmentId == assignmentId) _activeAssignmentId = null;
        });
      }

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
            observedAcceptanceScenarios['passive_probe'] = 'passed';
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
            observedAcceptanceScenarios['passive_probe'] = 'failed';
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
          observedAcceptanceScenarios['passive_probe'] = 'failed';
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
          consumesQuota: false,
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
            observedAcceptanceScenarios['live_probe'] = 'passed';
            addStage(
              stageId: 'live_probe',
              displayName: 'Live Probe',
              status: 'passed',
              durationMs: s6Timer.elapsedMilliseconds,
              diagnostics: 'Live probe Engine-controlled OK test passed.',
              consumesQuota: true,
            );
          } else {
            observedAcceptanceScenarios['live_probe'] = 'failed';
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
          observedAcceptanceScenarios['live_probe'] = 'failed';
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

      // --- STAGE 7: Representative Workstream Write ---
      final s7Timer = Stopwatch()..start();
      const writeSentinel = 'conclave-profile-lab-write-verified';
      final writeTarget = File('${scratchDir.path}/acceptance-write.txt');
      final workstreamWriteApplicable =
          expectedAcceptanceScenarios?['representative_workstream_write'] ==
              'passed';
      if (!workstreamWriteApplicable) {
        s7Timer.stop();
        observedAcceptanceScenarios['representative_workstream_write'] =
            'not_applicable';
        addStage(
          stageId: 'representative_workstream_write',
          displayName: 'Representative Workstream Write',
          status: 'skipped',
          durationMs: 0,
          diagnostics:
              'This Tool Profile does not declare the workstream_write capability.',
          consumesQuota: false,
          details: {'applicability': 'not_applicable'},
        );
      } else if (haltExecution) {
        s7Timer.stop();
        addStage(
          stageId: 'representative_workstream_write',
          displayName: 'Representative Workstream Write',
          status: 'skipped',
          durationMs: 0,
          diagnostics: 'Skipped due to prior live probe failure.',
          consumesQuota: false,
        );
      } else {
        try {
          await executeAssignment(
            label: 'representative-workstream-write',
            prompt: 'Create the file "acceptance-write.txt" in the current '
                'working directory and write exactly this UTF-8 text into it: '
                '$writeSentinel. Do not just describe the action. Then reply '
                'that the file was written.',
          );
          final wroteExpectedContent = await writeTarget.exists() &&
              await writeTarget.readAsString() == writeSentinel;
          s7Timer.stop();
          observedAcceptanceScenarios['representative_workstream_write'] =
              wroteExpectedContent ? 'passed' : 'failed';
          if (wroteExpectedContent) {
            addStage(
              stageId: 'representative_workstream_write',
              displayName: 'Representative Workstream Write',
              status: 'passed',
              durationMs: s7Timer.elapsedMilliseconds,
              diagnostics:
                  'Engine assignment wrote and verified the expected file in the isolated sandbox.',
              consumesQuota: true,
            );
          } else {
            haltExecution = true;
            addStage(
              stageId: 'representative_workstream_write',
              displayName: 'Representative Workstream Write',
              status: 'failed',
              durationMs: s7Timer.elapsedMilliseconds,
              diagnostics:
                  'Engine assignment completed without writing the expected file contents.',
              consumesQuota: true,
              issueCode: 'workstream_write_not_observed',
            );
          }
        } on Object catch (error) {
          s7Timer.stop();
          haltExecution = true;
          observedAcceptanceScenarios['representative_workstream_write'] =
              'failed';
          addStage(
            stageId: 'representative_workstream_write',
            displayName: 'Representative Workstream Write',
            status: 'failed',
            durationMs: s7Timer.elapsedMilliseconds,
            diagnostics: 'Engine execution failed: $error',
            consumesQuota: true,
            issueCode: error is CliWorkerEngineProbeException
                ? error.issueCode
                : 'engine_execution_failed',
          );
        }
      }

      // --- STAGE 8: Session Test ---
      final s8Timer = Stopwatch()..start();
      final durableSessionApplicable =
          expectedAcceptanceScenarios?['durable_session_start'] == 'passed';
      if (!durableSessionApplicable) {
        observedAcceptanceScenarios['durable_session_start'] = 'not_applicable';
        observedAcceptanceScenarios['durable_session_resume'] =
            'not_applicable';
        s8Timer.stop();
        addStage(
          stageId: 'session_test',
          displayName: 'Session Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics:
              'Session management is not declared by this Tool Profile.',
          consumesQuota: false,
          details: {'applicability': 'not_applicable'},
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
        try {
          final sessionMap =
              candidate.profile['session'] as Map<String, Object?>? ?? const {};
          final sessionKey = 'lab-${DateTime.now().microsecondsSinceEpoch}';
          await executeAssignment(
            label: 'session-create',
            prompt: 'Conclave Lab session creation probe. Reply briefly.',
            sessionPolicy: WorkerSessionPolicy.durableSession,
            sessionKey: sessionKey,
          );
          observedAcceptanceScenarios['durable_session_start'] = 'passed';
          final resumed = await executeAssignment(
            label: 'session-resume',
            prompt: 'Continue the Conclave Lab session probe. Reply briefly.',
            sessionPolicy: WorkerSessionPolicy.durableSession,
            sessionKey: sessionKey,
          );
          s8Timer.stop();
          observedAcceptanceScenarios['durable_session_resume'] = 'passed';
          addStage(
            stageId: 'session_test',
            displayName: 'Session Create and Resume',
            status: 'passed',
            durationMs: s8Timer.elapsedMilliseconds,
            diagnostics:
                'Engine completed durable session create and resume assignments.',
            consumesQuota: true,
            details: {
              'formatId': sessionMap['formatId'],
              'resumeOutputLength': resumed.output.length,
            },
          );
        } on Object catch (error) {
          s8Timer.stop();
          haltExecution = true;
          observedAcceptanceScenarios.putIfAbsent(
            'durable_session_start',
            () => 'failed',
          );
          observedAcceptanceScenarios['durable_session_resume'] = 'failed';
          addStage(
            stageId: 'session_test',
            displayName: 'Session Create and Resume',
            status: 'failed',
            durationMs: s8Timer.elapsedMilliseconds,
            diagnostics: 'Engine session execution failed: $error',
            consumesQuota: true,
            issueCode: error is CliWorkerEngineProbeException
                ? error.issueCode
                : 'session_test_failed',
          );
        }
      }

      // --- STAGE 9: Model Selection Test ---
      final s9Timer = Stopwatch()..start();
      final modelMap =
          candidate.profile['model'] as Map<String, Object?>? ?? {};
      final modelSelectionApplicable =
          expectedAcceptanceScenarios?['model_selection'] == 'passed';
      if (!modelSelectionApplicable) {
        observedAcceptanceScenarios['model_selection'] = 'not_applicable';
        s9Timer.stop();
        addStage(
          stageId: 'model_selection_test',
          displayName: 'Model Selection Test',
          status: 'skipped',
          durationMs: 0,
          diagnostics:
              'The Tool Profile does not declare a testable model selection.',
          consumesQuota: false,
          details: {'applicability': 'not_applicable'},
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
        final selectedModel =
            (modelMap['allowlist'] as List).whereType<String>().first;
        try {
          await executeAssignment(
            label: 'model-selection',
            prompt: 'Conclave Lab model selection probe. Reply briefly.',
            model: selectedModel,
          );
          s9Timer.stop();
          observedAcceptanceScenarios['model_selection'] = 'passed';
          addStage(
            stageId: 'model_selection_test',
            displayName: 'Model Selection Test',
            status: 'passed',
            durationMs: s9Timer.elapsedMilliseconds,
            diagnostics:
                'Engine completed an assignment using the declared model.',
            consumesQuota: true,
            details: {'model': selectedModel},
          );
        } on Object catch (error) {
          s9Timer.stop();
          haltExecution = true;
          observedAcceptanceScenarios['model_selection'] = 'failed';
          addStage(
            stageId: 'model_selection_test',
            displayName: 'Model Selection Test',
            status: 'failed',
            durationMs: s9Timer.elapsedMilliseconds,
            diagnostics: 'Engine model-selected execution failed: $error',
            consumesQuota: true,
            issueCode: error is CliWorkerEngineProbeException
                ? error.issueCode
                : 'model_selection_test_failed',
          );
        }
      }

      // --- STAGE 10: Cancellation ---
      final s10Timer = Stopwatch()..start();
      if (haltExecution) {
        addStage(
            stageId: 'cancellation_test',
            displayName: 'Cancellation',
            status: 'skipped',
            durationMs: 0,
            diagnostics: 'Skipped because a prior Engine execution failed.',
            consumesQuota: false);
      } else {
        final assignment = executeAssignment(
          label: 'cancellation',
          prompt:
              'Conclave Lab cancellation probe. This request will be cancelled.',
          timeout: const Duration(seconds: 30),
        );
        await Future<void>.delayed(const Duration(milliseconds: 750));
        await cancelCurrentTest();
        try {
          await assignment;
          s10Timer.stop();
          addStage(
              stageId: 'cancellation_test',
              displayName: 'Engine Cancellation',
              status: 'failed',
              durationMs: s10Timer.elapsedMilliseconds,
              diagnostics:
                  'The Engine assignment completed before cancellation was observed.',
              consumesQuota: true,
              issueCode: 'cancellation_not_observed');
          haltExecution = true;
        } on WorkerAssignmentCancelledException {
          s10Timer.stop();
          observedAcceptanceScenarios['cancellation'] = 'passed';
          addStage(
              stageId: 'cancellation_test',
              displayName: 'Engine Cancellation',
              status: 'passed',
              durationMs: s10Timer.elapsedMilliseconds,
              diagnostics:
                  'The active Engine assignment and provider process tree were cancelled.',
              consumesQuota: true);
        } on Object catch (error) {
          s10Timer.stop();
          observedAcceptanceScenarios['cancellation'] = 'failed';
          addStage(
              stageId: 'cancellation_test',
              displayName: 'Engine Cancellation',
              status: 'failed',
              durationMs: s10Timer.elapsedMilliseconds,
              diagnostics: 'Cancellation outcome was not confirmed: $error',
              consumesQuota: true,
              issueCode: 'cancellation_test_failed');
          haltExecution = true;
        }
      }

      // --- STAGE 11: Timeout ---
      final s11Timer = Stopwatch()..start();
      if (haltExecution) {
        addStage(
            stageId: 'timeout_test',
            displayName: 'Execution Timeout',
            status: 'skipped',
            durationMs: 0,
            diagnostics: 'Skipped because a prior Engine execution failed.',
            consumesQuota: false);
      } else {
        try {
          await executeAssignment(
            label: 'timeout',
            prompt: 'Conclave Lab timeout probe. Complete this request.',
            timeout: const Duration(seconds: 10),
          );
          s11Timer.stop();
          addStage(
              stageId: 'timeout_test',
              displayName: 'Execution Timeout',
              status: 'failed',
              durationMs: s11Timer.elapsedMilliseconds,
              diagnostics:
                  'The Engine returned before its ten-second deadline; timeout behavior was not observed.',
              consumesQuota: true,
              issueCode: 'timeout_not_observed');
        } on CliWorkerEngineProbeException catch (error) {
          s11Timer.stop();
          final passed = error.issueCode == WorkerIssueCode.deadlineExceeded;
          observedAcceptanceScenarios['timeout'] = passed ? 'passed' : 'failed';
          addStage(
              stageId: 'timeout_test',
              displayName: 'Execution Timeout',
              status: passed ? 'passed' : 'failed',
              durationMs: s11Timer.elapsedMilliseconds,
              diagnostics: passed
                  ? 'The Engine enforced the assignment deadline and terminated the process tree.'
                  : 'Engine execution ended before timeout: ${error.safeMessage}',
              consumesQuota: true,
              issueCode: passed ? null : error.issueCode);
          if (!passed) haltExecution = true;
        }
      }
      _activeSupervisor = null;
    } finally {
      final supervisor = _activeSupervisor;
      final assignmentId = _activeAssignmentId;
      Object? cleanupFailure;
      StackTrace? cleanupStack;
      Future<void> attemptCleanup(Future<void> Function() action) async {
        try {
          await action();
        } catch (error, stack) {
          cleanupFailure ??= error;
          cleanupStack ??= stack;
        }
      }

      if (supervisor != null && assignmentId != null) {
        await attemptCleanup(() async {
          await supervisor.cancel(assignmentId);
        });
      }
      if (supervisor != null) {
        await attemptCleanup(supervisor.shutdown);
      }
      _activeSupervisor = null;
      _activeAssignmentId = null;
      await attemptCleanup(() async {
        final parent = await scratchDir.parent.resolveSymbolicLinks();
        if (parent != canonicalRoot) {
          throw FileSystemException(
            'Refusing to remove scratch data outside the sandbox root',
            scratchDir.path,
          );
        }
        final scratchType = await FileSystemEntity.type(
          scratchDir.path,
          followLinks: false,
        );
        if (scratchType == FileSystemEntityType.directory) {
          await _deleteSandboxTreeWithoutFollowingLinks(scratchDir);
          await scratchDir.delete();
        } else if (scratchType == FileSystemEntityType.link) {
          await Link(scratchDir.path).delete();
          throw FileSystemException(
            'Sandbox scratch directory was replaced by a symbolic link',
            scratchDir.path,
          );
        } else if (scratchType != FileSystemEntityType.notFound) {
          await File(scratchDir.path).delete();
          throw FileSystemException(
            'Sandbox scratch directory changed type during execution',
            scratchDir.path,
          );
        }
      });
      if (cleanupFailure != null) {
        Error.throwWithStackTrace(cleanupFailure!, cleanupStack!);
      }
    }

    final endedAt = DateTime.now().toUtc();
    final overallResult =
        stages.any((s) => s.status == 'failed') ? 'fail' : 'pass';

    final allAcceptanceScenariosObserved =
        expectedAcceptanceScenarios != null &&
            cloudAcceptanceScenarioNames.every(
              (scenario) =>
                  observedAcceptanceScenarios[scenario] ==
                  expectedAcceptanceScenarios![scenario],
            );
    final acceptanceEvidence = overallResult == 'pass' &&
            allAcceptanceScenariosObserved &&
            detectedProviderToolVersion != null
        ? ToolProfileAcceptanceEvidence(
            profileDefinitionId: candidate.profileDefinitionId,
            releaseVersion: candidate.releaseVersion,
            profileDigest: candidate.payloadDigest,
            logicalWorkerTypeId: candidate.logicalWorkerTypeId,
            engineVersion: cliWorkerEngineVersion,
            providerToolName: candidate.providerToolName,
            providerToolVersion: detectedProviderToolVersion,
            acceptedAt: endedAt.toIso8601String(),
            scenarios: observedAcceptanceScenarios,
          )
        : null;

    return ProfileLabLadderResult(
      overallResult: overallResult,
      startedAt: startedAt,
      endedAt: endedAt,
      stages: stages,
      acceptanceEvidence: acceptanceEvidence,
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
      acceptanceEvidence: ladderRes.acceptanceEvidence,
      logs: ladderRes.logs,
    );
  }

  static bool _isEngineVersionCompatible(
      String version, String min, String maxExclusive) {
    final lower = _compareReleaseSemver(version, min);
    final upper = _compareReleaseSemver(version, maxExclusive);
    return lower != null && upper != null && lower >= 0 && upper < 0;
  }

  static int? _compareReleaseSemver(String left, String right) {
    final pattern = RegExp(
      r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
    );
    final a = pattern.firstMatch(left);
    final b = pattern.firstMatch(right);
    if (a == null || b == null) return null;
    for (var index = 1; index <= 3; index++) {
      final comparison = int.parse(a[index]!).compareTo(int.parse(b[index]!));
      if (comparison != 0) return comparison;
    }
    final aPre = a[4]?.split('.');
    final bPre = b[4]?.split('.');
    if (aPre == null || bPre == null) {
      if (aPre == bPre) return 0;
      return aPre == null ? 1 : -1;
    }
    for (var index = 0; index < aPre.length || index < bPre.length; index++) {
      if (index >= aPre.length) return -1;
      if (index >= bPre.length) return 1;
      final leftPart = aPre[index];
      final rightPart = bPre[index];
      if (leftPart == rightPart) continue;
      final leftNumeric = RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(leftPart);
      final rightNumeric = RegExp(r'^(0|[1-9][0-9]*)$').hasMatch(rightPart);
      if (leftNumeric && rightNumeric) {
        return int.parse(leftPart).compareTo(int.parse(rightPart));
      }
      if (leftNumeric != rightNumeric) return leftNumeric ? -1 : 1;
      return leftPart.compareTo(rightPart);
    }
    return 0;
  }
}
