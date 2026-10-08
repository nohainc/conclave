import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:conclave_workspace/platform_runtime.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

const _engineVersion = '1.0.0';

void main() {
  for (final profile in _officialProfiles) {
    final optIn = Platform.environment[profile.optInVariable] == '1';
    test(
      'real ${profile.definitionId} Profile acceptance',
      skip: optIn
          ? false
          : 'Set ${profile.optInVariable}=1 to use provider allowance',
      () async {
        await _runAcceptance(profile);
      },
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}

final _officialProfiles = <_OfficialProfile>[
  _OfficialProfile(
    definitionId: 'chatgpt-codex',
    logicalWorkerTypeId: 'chatgpt',
    profilePath: 'packages/tool-profile/test/fixtures/chatgpt-codex.v1.json',
    optInVariable: 'CONCLAVE_TEST_REAL_PROFILE_CHATGPT',
  ),
  _OfficialProfile(
    definitionId: 'gemini-antigravity',
    logicalWorkerTypeId: 'gemini',
    profilePath:
        'packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
    optInVariable: 'CONCLAVE_TEST_REAL_PROFILE_GEMINI',
  ),
];

final class _OfficialProfile {
  const _OfficialProfile({
    required this.definitionId,
    required this.logicalWorkerTypeId,
    required this.profilePath,
    required this.optInVariable,
  });

  final String definitionId;
  final String logicalWorkerTypeId;
  final String profilePath;
  final String optInVariable;
}

Future<void> _runAcceptance(_OfficialProfile official) async {
  final evidenceDirectory =
      Platform.environment['CONCLAVE_PROFILE_ACCEPTANCE_EVIDENCE_DIR'];
  if (evidenceDirectory == null || evidenceDirectory.isEmpty) {
    throw StateError(
      'Set CONCLAVE_PROFILE_ACCEPTANCE_EVIDENCE_DIR to retain release evidence.',
    );
  }
  final repository = _repositoryRoot();
  final profileFile = File('${repository.path}/${official.profilePath}');
  final profileBytes = await profileFile.readAsBytes();
  final digest = sha256.convert(profileBytes).toString();
  final profile = jsonDecode(utf8.decode(profileBytes)) as Map<String, Object?>;
  final capabilities = (profile['capabilities'] as List).cast<String>().toSet();
  final session = profile['session'] as Map<String, Object?>;
  final model = profile['model'] as Map<String, Object?>;
  final modelAllowlist = (model['allowlist'] as List?)?.cast<String>() ?? [];
  final modelSelectionTestable =
      model['supported'] == true && modelAllowlist.isNotEmpty;
  final durableSessionSupported = capabilities.contains('durable_session');
  if (durableSessionSupported != (session['supported'] == true)) {
    throw StateError(
      'Profile durable_session capability does not match session.supported.',
    );
  }
  final profileReleaseVersion = '${profile['releaseVersion']}';
  final root = await Directory.systemTemp.createTemp(
    'conclave-profile-acceptance-${official.definitionId}-',
  );
  final stateDirectory = await Directory('${root.path}/state').create();
  final threadDirectory = await Directory(
    '${root.path}/thread',
  ).create();
  final evidence = <String, Object?>{
    'formatVersion': 2,
    'profileDefinitionId': official.definitionId,
    'releaseVersion': profile['releaseVersion'],
    'profileReleaseVersion': profileReleaseVersion,
    'logicalWorkerTypeId': official.logicalWorkerTypeId,
    'profileDigest': digest,
    'engineVersion': _engineVersion,
    'providerToolName': profile['providerTool'] is Map
        ? (profile['providerTool'] as Map)['name']
        : null,
    'providerToolVersion': null,
    'acceptedAt': null,
    'scenarios': <String, Object?>{},
  };

  Future<void> scenario(String name, Future<void> Function() run) async {
    try {
      await run();
      (evidence['scenarios'] as Map<String, Object?>)[name] = 'passed';
    } catch (_) {
      (evidence['scenarios'] as Map<String, Object?>)[name] = 'failed';
      rethrow;
    } finally {
      await _writeEvidence(evidence, evidenceDirectory);
    }
  }

  Future<void> notApplicableScenario(String name) async {
    (evidence['scenarios'] as Map<String, Object?>)[name] = 'not_applicable';
    await _writeEvidence(evidence, evidenceDirectory);
  }

  try {
    await scenario('passive_probe', () async {
      final engine = await _EngineClient.start(
        official: official,
        repository: repository,
        profileFile: profileFile,
        profile: profile,
        digest: digest,
        stateDirectory: stateDirectory,
        threadDirectory: threadDirectory,
      );
      try {
        final result = await engine.exchange(
          ProbeRequest(
            requestId: 'accept-passive',
            mode: WorkerProbeMode.passive,
          ),
        );
        expect(result.terminal, isA<ProbeResult>());
        final probe = result.terminal as ProbeResult;
        expect(
          probe.ready,
          isTrue,
          reason: 'Passive probe reported not ready: ${probe.toJson()}',
        );
        expect(probe.providerToolVersion, isNotEmpty);
        evidence['providerToolVersion'] = probe.providerToolVersion;
        expect(
          probe.checks.map((check) => check.code),
          contains('provider_tool_version'),
        );
      } finally {
        await engine.close();
      }
    });

    await scenario('live_probe', () async {
      final engine = await _EngineClient.start(
        official: official,
        repository: repository,
        profileFile: profileFile,
        profile: profile,
        digest: digest,
        stateDirectory: stateDirectory,
        threadDirectory: threadDirectory,
      );
      try {
        final result = await engine.exchange(
          ProbeRequest(
            requestId: 'accept-live',
            mode: WorkerProbeMode.live,
            timeoutMs: 30000,
          ),
          timeout: const Duration(seconds: 90),
        );
        expect(result.terminal, isA<ProbeResult>());
        final probe = result.terminal as ProbeResult;
        expect(probe.ready, isTrue, reason: 'Live probe reported not ready.');
        expect(
          probe.checks
              .singleWhere((check) => check.code == 'provider_live_execution')
              .status,
          ProbeCheckStatus.passed,
        );
      } finally {
        await engine.close();
      }
    });

    if (!modelSelectionTestable) {
      await notApplicableScenario('model_selection');
    } else {
      await scenario('model_selection', () async {
        final engine = await _EngineClient.start(
          official: official,
          repository: repository,
          profileFile: profileFile,
          profile: profile,
          digest: digest,
          stateDirectory: stateDirectory,
          threadDirectory: threadDirectory,
        );
        try {
          final result = await engine.exchange(
            ExecuteRequest(
              requestId: 'accept-model-selection',
              assignmentId: 'profile-acceptance-model-selection',
              prompt: 'Reply with exactly MODEL_OK.',
              timeoutMs: 120000,
              sessionPolicy: WorkerSessionPolicy.stateless,
              model: modelAllowlist.first,
            ),
            timeout: const Duration(minutes: 3),
          );
          expect(result.terminal, isA<WorkerResult>());
        } finally {
          await engine.close();
        }
      });
    }

    if (!capabilities.contains('thread_write')) {
      await notApplicableScenario('representative_thread_write');
    } else {
      await scenario('representative_thread_write', () async {
        final marker =
            'profile-acceptance-${DateTime.now().microsecondsSinceEpoch}.txt';
        const markerContent = 'Conclave Profile acceptance write verified.';
        final engine = await _EngineClient.start(
          official: official,
          repository: repository,
          profileFile: profileFile,
          profile: profile,
          digest: digest,
          stateDirectory: stateDirectory,
          threadDirectory: threadDirectory,
        );
        try {
          final result = await engine.exchange(
            ExecuteRequest(
              requestId: 'accept-thread-write',
              assignmentId: 'profile-acceptance-write',
              prompt:
                  'In the current working directory, create $marker containing exactly this line: $markerContent. Do not modify other files. Then reply with exactly WRITE_OK.',
              timeoutMs: 120000,
              sessionPolicy: WorkerSessionPolicy.stateless,
            ),
            timeout: const Duration(minutes: 3),
          );
          expect(
            result.terminal,
            isA<WorkerResult>(),
            reason: result.terminal is WorkerErrorFrame
                ? jsonEncode((result.terminal as WorkerErrorFrame).toJson())
                : null,
          );
          expect(
            (result.terminal as WorkerResult).output,
            contains('WRITE_OK'),
          );
          expect(
            (await File('${threadDirectory.path}/$marker').readAsString())
                .trimRight(),
            markerContent,
          );
        } finally {
          await engine.close();
        }
      });
    }

    final sessionKey = 'accept_${DateTime.now().microsecondsSinceEpoch}';
    final rememberedPhrase = 'PROFILE-${DateTime.now().microsecondsSinceEpoch}';
    if (!durableSessionSupported) {
      await notApplicableScenario('durable_session_start');
      await notApplicableScenario('durable_session_resume');
    } else {
      await scenario('durable_session_start', () async {
        final engine = await _EngineClient.start(
          official: official,
          repository: repository,
          profileFile: profileFile,
          profile: profile,
          digest: digest,
          stateDirectory: stateDirectory,
          threadDirectory: threadDirectory,
        );
        try {
          final result = await engine.exchange(
            ExecuteRequest(
              requestId: 'accept-session-start',
              assignmentId: 'profile-acceptance-session-start',
              prompt:
                  'Remember the exact code $rememberedPhrase for the next turn. Reply with exactly SESSION_OK.',
              timeoutMs: 120000,
              sessionPolicy: WorkerSessionPolicy.durableSession,
              sessionKey: sessionKey,
            ),
            timeout: const Duration(minutes: 3),
          );
          expect(result.terminal, isA<WorkerResult>());
          expect(
              (result.terminal as WorkerResult).output, contains('SESSION_OK'));
        } finally {
          await engine.close();
        }
      });

      await scenario('durable_session_resume', () async {
        final engine = await _EngineClient.start(
          official: official,
          repository: repository,
          profileFile: profileFile,
          profile: profile,
          digest: digest,
          stateDirectory: stateDirectory,
          threadDirectory: threadDirectory,
        );
        try {
          final result = await engine.exchange(
            ExecuteRequest(
              requestId: 'accept-session-resume',
              assignmentId: 'profile-acceptance-session-resume',
              prompt:
                  'What exact code did I ask you to remember? Reply only with the code.',
              timeoutMs: 120000,
              sessionPolicy: WorkerSessionPolicy.durableSession,
              sessionKey: sessionKey,
            ),
            timeout: const Duration(minutes: 3),
          );
          expect(result.terminal, isA<WorkerResult>());
          expect(
            (result.terminal as WorkerResult).output,
            contains(rememberedPhrase),
          );
        } finally {
          await engine.close();
        }
      });
    }

    await scenario('timeout', () async {
      final engine = await _EngineClient.start(
        official: official,
        repository: repository,
        profileFile: profileFile,
        profile: profile,
        digest: digest,
        stateDirectory: stateDirectory,
        threadDirectory: threadDirectory,
      );
      try {
        final result = await engine.exchange(
          ExecuteRequest(
            requestId: 'accept-timeout',
            assignmentId: 'profile-acceptance-timeout',
            prompt: 'Reply with exactly OK.',
            timeoutMs: 1,
            sessionPolicy: WorkerSessionPolicy.stateless,
          ),
          timeout: const Duration(seconds: 20),
        );
        expect(result.terminal, isA<WorkerErrorFrame>());
        expect(
          (result.terminal as WorkerErrorFrame).code,
          WorkerIssueCode.deadlineExceeded,
        );
      } finally {
        await engine.close();
      }
    });

    await scenario('cancellation', () async {
      final engine = await _EngineClient.start(
        official: official,
        repository: repository,
        profileFile: profileFile,
        profile: profile,
        digest: digest,
        stateDirectory: stateDirectory,
        threadDirectory: threadDirectory,
      );
      Future<_ExchangeResult>? response;
      try {
        final firstProgress = Completer<void>();
        response = engine.exchange(
          ExecuteRequest(
            requestId: 'accept-cancel',
            assignmentId: 'profile-acceptance-cancel',
            prompt:
                'Write a detailed analysis of the current space and continue working for several minutes.',
            timeoutMs: 240000,
            sessionPolicy: WorkerSessionPolicy.stateless,
          ),
          timeout: const Duration(minutes: 5),
          onProgress: (_) {
            if (!firstProgress.isCompleted) firstProgress.complete();
          },
        );
        final observed = await Future.any<String>([
          firstProgress.future.then((_) => 'progress'),
          response.then((_) => 'completed'),
        ]).timeout(const Duration(seconds: 90));
        expect(
          observed,
          'progress',
          reason:
              'Provider completed before emitting progress for cancellation.',
        );
      } finally {
        await currentPlatformRuntime.terminateProcessTree(
          engine.process,
          force: true,
        );
        await engine.process.exitCode.timeout(const Duration(seconds: 10));
        await engine.dispose();
        await response?.then<void>((_) {}, onError: (_) {});
      }
    });

    evidence['acceptedAt'] = DateTime.now().toUtc().toIso8601String();
  } finally {
    await _writeEvidence(evidence, evidenceDirectory);
    await root.delete(recursive: true);
  }
}

Directory _repositoryRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/engines/cli_worker/bin/conclave_cli_worker.dart')
        .existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate the Conclave repository root.');
    }
    current = parent;
  }
}

Future<void> _writeEvidence(
  Map<String, Object?> evidence,
  String evidenceDirectory,
) async {
  final directory = Directory(evidenceDirectory);
  await directory.create(recursive: true);
  final file = File(
    '${directory.path}/${evidence['profileDefinitionId']}-acceptance.json',
  );
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
  );
}

final class _ExchangeResult {
  const _ExchangeResult(this.terminal, this.progress);

  final WorkerFrame terminal;
  final List<WorkerProgress> progress;
}

final class _EngineClient {
  _EngineClient(this.process)
      : lines = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        ) {
    stderrTask = process.stderr.drain<void>();
  }

  final Process process;
  final StreamIterator<String> lines;
  late final Future<void> stderrTask;

  static Future<_EngineClient> start({
    required _OfficialProfile official,
    required Directory repository,
    required File profileFile,
    required Map<String, Object?> profile,
    required String digest,
    required Directory stateDirectory,
    required Directory threadDirectory,
  }) async {
    final process = await currentPlatformRuntime.startIsolatedProcess(
      Platform.environment['DART_EXECUTABLE'] ?? Platform.resolvedExecutable,
      [
        '${repository.path}/engines/cli_worker/bin/conclave_cli_worker.dart',
        '--profile',
        profileFile.path,
        '--engine-version',
        _engineVersion,
        '--state-directory',
        stateDirectory.path,
      ],
      workingDirectory: threadDirectory.path,
      includeParentEnvironment: true,
    );
    final client = _EngineClient(process);
    try {
      final initialized = await client.exchange(
        InitializeRequest(
          requestId: 'accept-init',
          workerTypeId: official.logicalWorkerTypeId,
          expectedEngineVersion: _engineVersion,
          profileDefinitionId: official.definitionId,
          profileReleaseVersion: '${profile['releaseVersion']}',
          profileDigest: digest,
        ),
        timeout: const Duration(seconds: 30),
      );
      expect(initialized.terminal, isA<InitializeResult>());
      final result = initialized.terminal as InitializeResult;
      expect(result.workerTypeId, official.logicalWorkerTypeId);
      expect(result.profileDefinitionId, official.definitionId);
      expect(result.profileReleaseVersion, '${profile['releaseVersion']}');
      return client;
    } on Object {
      await currentPlatformRuntime.terminateProcessTree(process, force: true);
      await process.exitCode;
      await client.dispose();
      rethrow;
    }
  }

  Future<_ExchangeResult> exchange(
    WorkerFrame request, {
    Duration timeout = const Duration(minutes: 3),
    void Function(WorkerProgress progress)? onProgress,
  }) async {
    process.stdin.writeln(request.encode());
    await process.stdin.flush();
    final progress = <WorkerProgress>[];
    while (await lines.moveNext().timeout(timeout)) {
      final frame = decodeWorkerFrame(lines.current);
      if (frame is WorkerProgress && frame.requestId == request.requestId) {
        progress.add(frame);
        onProgress?.call(frame);
        continue;
      }
      if (frame.requestId != request.requestId) continue;
      if (frame is WorkerResult ||
          frame is WorkerErrorFrame ||
          frame is ProbeResult ||
          frame is InitializeResult) {
        return _ExchangeResult(frame, progress);
      }
    }
    throw TimeoutException('CLI Worker Engine closed before replying.');
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 10));
    await dispose();
  }

  Future<void> dispose() async {
    await lines.cancel();
    await stderrTask;
  }
}
