import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_workspace/platform_runtime.dart';
import 'package:syntila_worker_protocol/syntila_worker_protocol.dart';
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
    optInVariable: 'SYNTILA_TEST_REAL_PROFILE_CHATGPT',
  ),
  _OfficialProfile(
    definitionId: 'gemini-antigravity',
    logicalWorkerTypeId: 'gemini',
    profilePath:
        'packages/tool-profile/test/fixtures/gemini-antigravity.v1.json',
    optInVariable: 'SYNTILA_TEST_REAL_PROFILE_GEMINI',
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
      Platform.environment['SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR'];
  if (evidenceDirectory == null || evidenceDirectory.isEmpty) {
    throw StateError(
      'Set SYNTILA_PROFILE_ACCEPTANCE_EVIDENCE_DIR to retain release evidence.',
    );
  }
  final repository = _repositoryRoot();
  final profileFile = File('${repository.path}/${official.profilePath}');
  final profileBytes = await profileFile.readAsBytes();
  final digest = sha256.convert(profileBytes).toString();
  final profile = jsonDecode(utf8.decode(profileBytes)) as Map<String, Object?>;
  final profileReleaseVersion = '${profile['releaseVersion']}';
  final root = await Directory.systemTemp.createTemp(
    'syntila-profile-acceptance-${official.definitionId}-',
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

    // The live probe is the Profile's usage command; it calls no model.
    await scenario('usage_check', () async {
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
        expect(probe.ready, isTrue, reason: 'Usage check reported not ready.');
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

    evidence['acceptedAt'] = DateTime.now().toUtc().toIso8601String();
  } finally {
    await _writeEvidence(evidence, evidenceDirectory);
    await root.delete(recursive: true);
  }
}

Directory _repositoryRoot() {
  var current = Directory.current;
  while (true) {
    if (File('${current.path}/engines/cli_worker/bin/syntila_cli_worker.dart')
        .existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate the Syntila repository root.');
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
        '${repository.path}/engines/cli_worker/bin/syntila_cli_worker.dart',
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
