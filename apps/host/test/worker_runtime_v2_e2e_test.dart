import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_host/process_tree.dart';
import 'package:conclave_host/worker_release_manifest.dart';
import 'package:conclave_host/worker_release_catalog.dart';
import 'package:conclave_host/worker_release_verifier.dart';
import 'package:conclave_host/worker_candidate_validator.dart';
import 'package:conclave_host/worker_diagnostic_store.dart';
import 'package:conclave_host/worker_process_supervisor.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/worker_version_store.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Directory scratch;
  late String workerExecutable;
  late Directory stateDirectory;
  late Directory packageRoot;
  late List<int> archiveBytes;
  late Map<String, Object?> releaseManifest;
  late WorkerReleaseAdmission admission;
  late Ed25519ReleaseFixture signingFixture;

  setUpAll(() async {
    final repository = Directory.current.parent.parent;
    final workerPackage = Directory('${repository.path}/workers/test_worker');
    scratch = await Directory.systemTemp.createTemp('conclave-worker-v2-');
    stateDirectory = Directory('${scratch.path}/sessions');
    packageRoot = Directory('${scratch.path}/artifact');
    final executableName = 'test_worker${Platform.isWindows ? '.exe' : ''}';
    workerExecutable = '${packageRoot.path}/bin/$executableName';
    await Directory('${packageRoot.path}/bin').create(recursive: true);

    final compile = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'exe',
        'bin/test_worker.dart',
        '-o',
        '${scratch.path}/compiled_test_worker',
      ],
      workingDirectory: workerPackage.path,
    );
    expect(compile.exitCode, 0, reason: '${compile.stdout}\n${compile.stderr}');
    final compiled = File('${scratch.path}/compiled_test_worker');
    await compiled.copy(workerExecutable);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['755', workerExecutable]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
    }

    archiveBytes = await _archive(packageRoot);
    final packageDigest = await digestWorkerPackageDirectory(packageRoot);
    signingFixture = await Ed25519ReleaseFixture.create();
    releaseManifest = {
      'manifestVersion': workerReleaseManifestVersion,
      'workerTypeId': 'test',
      'workerVersion': '0.1.0',
      'publisher': fixturePublisher,
      'platform': currentWorkerPlatform(),
      'protocol': {'min': '3.0', 'max': '3.0'},
      'stateSchema': {'readMin': 1, 'readMax': 1, 'write': 1},
      'capabilities': [
        'initialize',
        'probe',
        'execute',
        'progress',
        'durable_session',
      ],
      'permissions': <String>[],
      'executable': 'bin/$executableName',
      'releaseChannel': 'development',
      'packageDigest': packageDigest,
      'archiveSha256': sha256.convert(archiveBytes).toString(),
      'signingKeyId': fixtureKeyId,
      'signature': '',
    };
    await signingFixture.signWorkerReleaseManifest(releaseManifest);
    admission = await WorkerReleaseVerifier.verify(
      manifestInput: releaseManifest,
      packageRoot: packageRoot,
      archiveBytes: archiveBytes,
      expectedWorkerTypeId: 'test',
      platform: currentWorkerPlatform(),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      readableStateSchemaVersion: 1,
    );
    workerExecutable = admission.executable.path;
  });

  tearDownAll(() async {
    if (await scratch.exists()) await scratch.delete(recursive: true);
  });

  test('v2 migration supervises Worker initialize, probe and execution',
      () async {
    expect(admission.manifest.workerTypeId, 'test');
    expect(admission.manifest.platform, currentWorkerPlatform());
    expect(
        releaseManifest.keys,
        containsAll([
          'workerVersion',
          'protocol',
          'stateSchema',
          'archiveSha256',
          'signature',
        ]));
    expect(releaseManifest.keys, isNot(contains('prerequisites')));
    expect(releaseManifest.keys, isNot(contains('authStrategies')));

    await WorkerCandidateValidator().validate(
      admission,
      stateDirectory: stateDirectory,
    );

    final progress = <WorkerProgress>[];
    final launchRuntime = _RecordingPlatformRuntime(currentPlatformRuntime);
    final result = await WorkerProcessSupervisor(
      platformRuntime: launchRuntime,
    ).execute(
      executable: admission.executable,
      workstreamDirectory: scratch,
      stateDirectory: stateDirectory,
      workerTypeId: 'test',
      workerVersion: '0.1.0',
      providerToolName: 'Fake_CLI',
      providerToolVersion: '9.8.7',
      request: ExecuteRequest(
        requestId: 'execute-1',
        assignmentId: 'assignment-1',
        prompt: 'deterministic input',
        timeoutMs: 5000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
      onProgress: progress.add,
    );
    expect(progress, hasLength(3));
    expect(result.result.output, 'echo: deterministic input');
    expect(launchRuntime.includeParentEnvironment, isFalse);
    expect(launchRuntime.environment['PATH'], isNotEmpty);
    expect(launchRuntime.environment['HOME'], isNotEmpty);
    expect(
      launchRuntime.environment['CONCLAVE_WORKER_STATE_DIR'],
      stateDirectory.path,
    );
    expect(launchRuntime.environment.containsKey('OPENAI_API_KEY'), isFalse);
    expect(launchRuntime.workingDirectory, scratch.path);
    final diagnosticReport = await WorkerDiagnosticStore(
      directory: Directory('${scratch.path}/logs'),
    ).createCopyableReport();
    expect(diagnosticReport, contains('Conclave Worker diagnostic report'));
    expect(diagnosticReport, contains('assignment.completed'));
    expect(diagnosticReport, contains('worker.assignment.started'));
    expect(diagnosticReport, isNot(contains('deterministic input')));
    final logRecords = diagnosticReport
        .split('\n')
        .where((line) => line.startsWith('{'))
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    for (final event in logRecords) {
      expect(event['level'], isA<String>());
      expect(event['workerTypeId'], 'test');
      expect(event['workerVersion'], '0.1.0');
    }
    final completed = logRecords.firstWhere(
      (event) => event['event'] == 'assignment.completed',
    );
    expect(completed['protocolStage'], 'execute');
    expect(completed['runId'], 'assignment-1');
    expect(completed['durationMs'], isA<int>());
    expect(completed['processExitCode'], 0);
    expect(completed['providerToolName'], 'Fake_CLI');
    expect(completed['providerToolVersion'], '9.8.7');
    expect(
      logRecords.any((event) => event['providerToolVersion'] == '1.0.0'),
      isTrue,
    );
  });

  test(
      'release catalog omits newer Worker versions incompatible with this Workspace',
      () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/catalog-workers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
    );
    final incompatibleManifest = Map<String, Object?>.from(releaseManifest)
      ..['workerVersion'] = '0.2.0'
      ..['stateSchema'] = {'readMin': 2, 'readMax': 2, 'write': 2};
    await signingFixture.signWorkerReleaseManifest(incompatibleManifest);
    final catalog = WorkerReleaseCatalog(
      cloudUri: Uri.parse('https://cloud.test'),
      store: store,
      releaseLoader: (workerTypeId, channel) async => [
        AvailableWorkerRelease(
          workerTypeId: workerTypeId,
          version: '0.2.0',
          platform: currentWorkerPlatform(),
          channel: channel,
          manifest: incompatibleManifest,
          publishedAt: null,
        ),
        AvailableWorkerRelease(
          workerTypeId: workerTypeId,
          version: '0.1.0',
          platform: currentWorkerPlatform(),
          channel: channel,
          manifest: releaseManifest,
          publishedAt: null,
        ),
      ],
    );

    final compatible = await catalog.latestCompatibleRelease(
      'test',
      channel: 'development',
      newerThan: '0.0.9',
    );
    expect(compatible?.version, '0.1.0');
    expect(
      await catalog.latestCompatibleRelease(
        'test',
        channel: 'development',
        newerThan: '0.1.0',
      ),
      isNull,
    );
  });

  test('a crashed Worker produces a redacted copyable diagnostic report',
      () async {
    final supervisor = WorkerProcessSupervisor();
    await expectLater(
      supervisor.execute(
        executable: admission.executable,
        workstreamDirectory: scratch,
        stateDirectory: stateDirectory,
        workerTypeId: 'test',
        workerVersion: '0.1.0',
        request: ExecuteRequest(
          requestId: 'crash-request',
          assignmentId: 'crash-assignment',
          prompt: 'crash=17;never log this prompt',
          timeoutMs: 5000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      ),
      throwsA(
        isA<WorkerProcessFailure>().having(
          (failure) => failure.issueCode,
          'issueCode',
          WorkerIssueCode.workerInternalFailure,
        ),
      ),
    );

    final report = await WorkerDiagnosticStore(
      directory: Directory('${scratch.path}/logs'),
    ).createCopyableReport();
    expect(report, contains('assignment.failed'));
    expect(report, contains('crash-assignment'));
    expect(report, contains('worker_internal_failure'));
    expect(report, isNot(contains('never log this prompt')));
    final records = report
        .split('\n')
        .where((line) => line.startsWith('{'))
        .map((line) => jsonDecode(line) as Map<String, Object?>);
    final failure = records.firstWhere(
      (record) =>
          record['event'] == 'assignment.failed' &&
          record['runId'] == 'crash-assignment',
    );
    expect(failure['errorCode'], WorkerIssueCode.workerInternalFailure);
    expect(failure['processExitCode'], 17);
  });

  test('release verification rejects altered metadata and artifact bytes',
      () async {
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: {...releaseManifest, 'workerVersion': '0.1.1'},
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsA(isA<StateError>()),
    );

    final corruptedArchive = [...archiveBytes]..[0] ^= 1;
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: releaseManifest,
        packageRoot: packageRoot,
        archiveBytes: corruptedArchive,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test(
      'release admission rejects platform, protocol, state and permission gaps',
      () async {
    final otherPlatform =
        currentWorkerPlatform() == 'linux-x64' ? 'macos-arm64' : 'linux-x64';
    final wrongPlatform = Map<String, Object?>.from(releaseManifest)
      ..['platform'] = otherPlatform
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(wrongPlatform);
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: wrongPlatform,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsFormatException,
    );

    final incompatibleWorkerProtocol =
        Map<String, Object?>.from(releaseManifest)
          ..['protocol'] = {'min': '2.0', 'max': '2.9'}
          ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(incompatibleWorkerProtocol);
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: incompatibleWorkerProtocol,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsStateError,
    );

    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: releaseManifest,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        supportedProtocolVersions: const {'2.9'},
        readableStateSchemaVersion: 1,
      ),
      throwsStateError,
    );

    final wrongType = Map<String, Object?>.from(releaseManifest)
      ..['workerTypeId'] = 'other'
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(wrongType);
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: wrongType,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsFormatException,
    );

    final unreadableState = Map<String, Object?>.from(releaseManifest)
      ..['stateSchema'] = {'readMin': 2, 'readMax': 3, 'write': 2}
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(unreadableState);
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: unreadableState,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsStateError,
    );

    final deniedPermission = Map<String, Object?>.from(releaseManifest)
      ..['permissions'] = ['network:openai']
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(deniedPermission);
    await expectLater(
      WorkerReleaseVerifier.verify(
        manifestInput: deniedPermission,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      ),
      throwsStateError,
    );
  });

  test('installs coexisting Worker versions and atomically switches active',
      () async {
    var hasActiveAssignments = false;
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/Workers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      hasActiveAssignments: () => hasActiveAssignments,
      candidateHealthCheck: _AcceptCandidateHealthCheck(),
      retentionLimit: 2,
    );
    final firstArchive = List<int>.from(archiveBytes);
    final firstManifest = Map<String, Object?>.from(releaseManifest);
    final firstExecutableBytes = await File(workerExecutable).readAsBytes();

    final firstInstall = await store.installArchive(
      manifestInput: firstManifest,
      archiveBytes: firstArchive,
      expectedWorkerTypeId: 'test',
    );
    final stateFile = File('${store.stateDirectory('test').path}/session.json');
    final logFile = File('${store.logsDirectory('test').path}/worker.log');
    await stateFile.writeAsString('durable-state');
    await logFile.writeAsString('diagnostic-log');

    await File('${packageRoot.path}/version.txt').writeAsString('second');
    final secondArchive = await _archive(packageRoot);
    final secondManifest = Map<String, Object?>.from(releaseManifest)
      ..['workerVersion'] = '0.1.1'
      ..['packageDigest'] = await digestWorkerPackageDirectory(packageRoot)
      ..['archiveSha256'] = sha256.convert(secondArchive).toString()
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(secondManifest);
    final secondInstall = await store.installArchive(
      manifestInput: secondManifest,
      archiveBytes: secondArchive,
      expectedWorkerTypeId: 'test',
    );

    expect(firstInstall.path, isNot(secondInstall.path));
    expect(await firstInstall.exists(), isTrue);
    expect(await secondInstall.exists(), isTrue);
    expect(await store.activeVersion('test'), '0.1.1');
    expect(await store.lastKnownGoodVersion('test'), '0.1.0');
    final incompatibleStateStore = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/Workers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 2,
    );
    await expectLater(
      incompatibleStateStore.activateVersion('test', '0.1.0'),
      throwsStateError,
    );
    expect(await store.activeVersion('test'), '0.1.1');
    final conflictingManifest = Map<String, Object?>.from(secondManifest)
      ..['releaseChannel'] = 'stable'
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(conflictingManifest);
    await expectLater(
      store.installArchive(
        manifestInput: conflictingManifest,
        archiveBytes: secondArchive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await store.activeVersion('test'), '0.1.1');
    final expectedActiveExecutable = File(
      '${secondInstall.path}${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}${Platform.isWindows ? 'test_worker.exe' : 'test_worker'}',
    );
    expect(
      await (await store.activeExecutable('test'))!.resolveSymbolicLinks(),
      await expectedActiveExecutable.resolveSymbolicLinks(),
    );
    expect(
      await File(
        '${firstInstall.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}${Platform.isWindows ? 'test_worker.exe' : 'test_worker'}',
      ).readAsBytes(),
      firstExecutableBytes,
    );
    expect(await stateFile.readAsString(), 'durable-state');
    expect(await logFile.readAsString(), 'diagnostic-log');

    await store.activateVersion('test', '0.1.0');
    expect(await store.activeVersion('test'), '0.1.0');
    expect(await store.lastKnownGoodVersion('test'), '0.1.1');

    await File('${packageRoot.path}/version.txt').writeAsString('third');
    final thirdArchive = await _archive(packageRoot);
    final thirdManifest = Map<String, Object?>.from(secondManifest)
      ..['workerVersion'] = '0.1.2'
      ..['packageDigest'] = await digestWorkerPackageDirectory(packageRoot)
      ..['archiveSha256'] = sha256.convert(thirdArchive).toString()
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(thirdManifest);
    final thirdInstall = await store.installArchive(
      manifestInput: thirdManifest,
      archiveBytes: thirdArchive,
      expectedWorkerTypeId: 'test',
    );
    expect(await store.activeVersion('test'), '0.1.2');
    expect(await store.lastKnownGoodVersion('test'), '0.1.0');
    expect(await firstInstall.exists(), isTrue);
    expect(await secondInstall.exists(), isFalse);
    expect(await thirdInstall.exists(), isTrue);
    expect(await stateFile.readAsString(), 'durable-state');
    expect(await logFile.readAsString(), 'diagnostic-log');
    expect((await store.releaseState('test')).updatePolicy,
        WorkerUpdatePolicy.notify);
    expect(await store.installedVersions('test'), ['0.1.2', '0.1.0']);
    hasActiveAssignments = true;
    await expectLater(
      store.activateVersion('test', '0.1.0'),
      throwsA(isA<WorkerActivationDeferred>()),
    );
    expect(await store.activeVersion('test'), '0.1.2');
    hasActiveAssignments = false;

    await store.setUpdatePolicy('test', WorkerUpdatePolicy.pinned,
        pinnedVersion: '0.1.0');
    expect(await store.activeVersion('test'), '0.1.0');
    expect((await store.releaseState('test')).pinnedVersion, '0.1.0');
    await expectLater(
      store.activateVersion('test', '0.1.2'),
      throwsStateError,
    );
    await store.rollbackToLastKnownGood('test');
    expect(await store.activeVersion('test'), '0.1.2');
    expect((await store.releaseState('test')).updatePolicy,
        WorkerUpdatePolicy.notify);

    final chatgptManifest = Map<String, Object?>.from(thirdManifest)
      ..['workerTypeId'] = 'chatgpt'
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(chatgptManifest);
    await store.installArchive(
      manifestInput: chatgptManifest,
      archiveBytes: thirdArchive,
      expectedWorkerTypeId: 'chatgpt',
    );
    await store.setUpdatePolicy('chatgpt', WorkerUpdatePolicy.automatic);
    final geminiManifest = Map<String, Object?>.from(thirdManifest)
      ..['workerTypeId'] = 'gemini'
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(geminiManifest);
    await store.installArchive(
      manifestInput: geminiManifest,
      archiveBytes: thirdArchive,
      expectedWorkerTypeId: 'gemini',
    );
    expect((await store.releaseState('chatgpt')).updatePolicy,
        WorkerUpdatePolicy.automatic);
    expect((await store.releaseState('gemini')).updatePolicy,
        WorkerUpdatePolicy.notify);

    final orphan = Directory(
      '${store.versionsDirectory('test').path}${Platform.pathSeparator}'
      '.staging-orphan',
    );
    await orphan.create();
    await store.cleanupOrphanStagingDirectories(
      workerTypeId: 'test',
      minimumAge: Duration.zero,
    );
    expect(await orphan.exists(), isFalse);
  });

  test('upgrade, rollback, pin and unpin remain executable workflows',
      () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/VersionWorkflowWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      candidateHealthCheck: WorkerCandidateValidator(),
      retentionLimit: 4,
    );
    final supervisor = WorkerProcessSupervisor();

    Future<String> executeActive(String version, String requestId) async {
      final executable = await store.activeExecutable('test');
      expect(executable, isNotNull);
      expect(await store.activeVersion('test'), version);
      final result = await supervisor.execute(
        executable: executable!,
        workstreamDirectory: scratch,
        stateDirectory: store.stateDirectory('test'),
        workerTypeId: 'test',
        workerVersion: version,
        request: ExecuteRequest(
          requestId: requestId,
          assignmentId: 'assignment-$requestId',
          prompt: 'version workflow',
          timeoutMs: 5000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
      );
      return result.result.output;
    }

    final version100 = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.0',
    );
    await store.installArchive(
      manifestInput: version100.manifest,
      archiveBytes: version100.archive,
      expectedWorkerTypeId: 'test',
    );
    expect(await store.activeVersion('test'), '1.0.0');
    expect(await executeActive('1.0.0', 'before-update'),
        'echo: version workflow');

    final version110 = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.1.0',
    );
    await store.installArchive(
      manifestInput: version110.manifest,
      archiveBytes: version110.archive,
      expectedWorkerTypeId: 'test',
    );
    expect(await store.activeVersion('test'), '1.1.0');
    expect(await store.lastKnownGoodVersion('test'), '1.0.0');
    expect(
        await executeActive('1.1.0', 'after-update'), 'echo: version workflow');

    await store.rollbackToLastKnownGood('test');
    expect(await store.activeVersion('test'), '1.0.0');
    expect(await store.lastKnownGoodVersion('test'), '1.1.0');
    expect(await executeActive('1.0.0', 'after-rollback'),
        'echo: version workflow');

    await store.setUpdatePolicy(
      'test',
      WorkerUpdatePolicy.pinned,
      pinnedVersion: '1.0.0',
    );
    final version120 = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.2.0',
    );
    var archiveDownloads = 0;
    final release120 = AvailableWorkerRelease(
      workerTypeId: 'test',
      version: '1.2.0',
      platform: currentWorkerPlatform(),
      channel: 'development',
      manifest: version120.manifest,
      publishedAt: '2026-09-30T00:00:00Z',
    );
    final catalog = WorkerReleaseCatalog(
      cloudUri: Uri.parse('http://localhost'),
      store: store,
      releaseLoader: (workerTypeId, channel) async => [release120],
      archiveLoader: (_) async {
        archiveDownloads++;
        return version120.archive;
      },
    );
    try {
      expect(
          (await catalog.latestRelease('test', channel: 'development'))
              ?.version,
          '1.2.0');
      await catalog.refreshAutomaticUpdate('test');
      expect(await store.activeVersion('test'), '1.0.0');
      expect(archiveDownloads, 0,
          reason: 'pinned Worker must not download or activate a new release');

      await store.setUpdatePolicy('test', WorkerUpdatePolicy.notify);
      expect((await store.releaseState('test')).pinnedVersion, isNull);
      await catalog.installRelease(release120);
      expect(await store.activeVersion('test'), '1.2.0');
      expect(await store.lastKnownGoodVersion('test'), '1.0.0');
      expect(archiveDownloads, 1);
      expect(await executeActive('1.2.0', 'after-unpin-update'),
          'echo: version workflow');
    } finally {
      catalog.close();
    }
  });

  test(
      'invalid or unhealthy Worker candidates never replace the active release',
      () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/RejectedCandidatesWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      candidateHealthCheck: WorkerCandidateValidator(),
      retentionLimit: 8,
    );
    final version100 = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.0',
    );
    await store.installArchive(
      manifestInput: version100.manifest,
      archiveBytes: version100.archive,
      expectedWorkerTypeId: 'test',
    );

    final badSignature = Map<String, Object?>.from(version100.manifest)
      ..['workerVersion'] = '1.0.1'
      ..['signature'] = base64.encode(List<int>.filled(64, 0));
    await expectLater(
      store.installArchive(
        manifestInput: badSignature,
        archiveBytes: version100.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(isA<StateError>()),
    );

    final brokenExecutable = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.2',
      invalidExecutable: true,
    );
    await expectLater(
      store.installArchive(
        manifestInput: brokenExecutable.manifest,
        archiveBytes: brokenExecutable.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(isA<WorkerCandidateValidationFailure>()),
    );

    final protocolMismatch = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.3',
      protocol: {'min': '2.0', 'max': '2.9'},
    );
    await expectLater(
      store.installArchive(
        manifestInput: protocolMismatch.manifest,
        archiveBytes: protocolMismatch.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsStateError,
    );

    final stateMismatch = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.4',
      stateSchema: {'readMin': 2, 'readMax': 2, 'write': 2},
    );
    await expectLater(
      store.installArchive(
        manifestInput: stateMismatch.manifest,
        archiveBytes: stateMismatch.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsStateError,
    );

    final failedProbe = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.5',
      failPassiveProbe: true,
    );
    await expectLater(
      store.installArchive(
        manifestInput: failedProbe.manifest,
        archiveBytes: failedProbe.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(
        isA<WorkerCandidateValidationFailure>().having(
          (failure) => failure.issueCode,
          'issueCode',
          WorkerIssueCode.providerToolUnavailable,
        ),
      ),
    );

    final crashedCandidate = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.6',
      crashOnStart: true,
    );
    await expectLater(
      store.installArchive(
        manifestInput: crashedCandidate.manifest,
        archiveBytes: crashedCandidate.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(
        isA<WorkerCandidateValidationFailure>().having(
          (failure) => failure.issueCode,
          'issueCode',
          WorkerIssueCode.workerInternalFailure,
        ),
      ),
    );

    expect(await store.activeVersion('test'), '1.0.0');
    expect(await store.lastKnownGoodVersion('test'), isNull);
  });

  test('active assignment defers Worker update until its process exits',
      () async {
    var assignmentActive = false;
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/ActiveAssignmentUpdateWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      hasActiveAssignments: () => assignmentActive,
      candidateHealthCheck: WorkerCandidateValidator(),
    );
    final version100 = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.0.0',
    );
    await store.installArchive(
      manifestInput: version100.manifest,
      archiveBytes: version100.archive,
      expectedWorkerTypeId: 'test',
    );
    final version110 = await _buildTestWorkerRelease(
      scratch: scratch,
      signingFixture: signingFixture,
      baseManifest: releaseManifest,
      version: '1.1.0',
    );

    final supervisor = WorkerProcessSupervisor();
    final assignmentStarted = Completer<void>();
    assignmentActive = true;
    final assignment = supervisor.execute(
      executable: (await store.activeExecutable('test'))!,
      workstreamDirectory: scratch,
      stateDirectory: store.stateDirectory('test'),
      workerTypeId: 'test',
      workerVersion: '1.0.0',
      request: ExecuteRequest(
        requestId: 'phase22-active-request',
        assignmentId: 'phase22-active-assignment',
        prompt: 'delay=30000;assignment still running',
        timeoutMs: 60000,
        sessionPolicy: WorkerSessionPolicy.stateless,
      ),
      onProgress: (_) {
        if (!assignmentStarted.isCompleted) assignmentStarted.complete();
      },
    );
    await assignmentStarted.future.timeout(const Duration(seconds: 5));
    expect(assignmentActive, isTrue);

    await expectLater(
      store.installArchive(
        manifestInput: version110.manifest,
        archiveBytes: version110.archive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(isA<WorkerActivationDeferred>()),
    );
    expect(await store.activeVersion('test'), '1.0.0');
    expect(await store.versionDirectory('test', '1.1.0').exists(), isTrue,
        reason: 'verified release may remain staged for a later activation');

    await supervisor.cancel('phase22-active-assignment');
    await expectLater(assignment, throwsA(isA<WorkerProcessFailure>()));
    assignmentActive = false;
    await store.activateCandidate('test', '1.1.0');
    expect(await store.activeVersion('test'), '1.1.0');
  });

  test('Worker store rejects archive path traversal before extraction',
      () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/UnsafeWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
    );
    final unsafeArchive = await _archive(packageRoot, extraPath: '../escape');
    final unsafeManifest = Map<String, Object?>.from(releaseManifest)
      ..['archiveSha256'] = sha256.convert(unsafeArchive).toString()
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(unsafeManifest);

    await expectLater(
      store.installArchive(
        manifestInput: unsafeManifest,
        archiveBytes: unsafeArchive,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await File('${scratch.path}/escape').exists(), isFalse);
    expect(
      await store.versionDirectory('test', '0.1.0').exists(),
      isFalse,
    );
  });

  test('automatic policy installs only a newer Worker catalog release',
      () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/AutomaticWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      candidateHealthCheck: _AcceptCandidateHealthCheck(),
    );
    await store.installArchive(
      manifestInput: releaseManifest,
      archiveBytes: archiveBytes,
      expectedWorkerTypeId: 'test',
    );
    await store.setUpdatePolicy('test', WorkerUpdatePolicy.automatic);

    final newerManifest = Map<String, Object?>.from(releaseManifest)
      ..['workerVersion'] = '0.1.1'
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(newerManifest);
    var catalogReads = 0;
    var archiveReads = 0;
    final catalog = WorkerReleaseCatalog(
      cloudUri: Uri.parse('http://localhost'),
      store: store,
      releaseLoader: (workerTypeId, channel) async {
        catalogReads++;
        return [
          AvailableWorkerRelease(
            workerTypeId: workerTypeId,
            version: '0.1.1',
            platform: currentWorkerPlatform(),
            channel: channel,
            manifest: newerManifest,
            publishedAt: '2026-09-30T00:00:00Z',
          ),
        ];
      },
      archiveLoader: (_) async {
        archiveReads++;
        return archiveBytes;
      },
    );
    try {
      await catalog.refreshAutomaticUpdate('test');
      expect(await store.activeVersion('test'), '0.1.1');
      expect(catalogReads, 1);
      expect(archiveReads, 1);
    } finally {
      catalog.close();
    }
  });

  test('v2 migration installs a signed Worker release', () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/EnsureWorkerRelease'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      candidateHealthCheck: _AcceptCandidateHealthCheck(),
    );
    final catalog = WorkerReleaseCatalog(
      cloudUri: Uri.parse('http://localhost'),
      store: store,
      releaseLoader: (workerTypeId, channel) async => [
        AvailableWorkerRelease(
          workerTypeId: workerTypeId,
          version: '0.1.0',
          platform: currentWorkerPlatform(),
          channel: channel,
          manifest: releaseManifest,
          publishedAt: null,
        ),
      ],
      archiveLoader: (_) async => archiveBytes,
    );
    try {
      expect(await catalog.ensureWorkerRelease('test'), isTrue);
      expect(await store.activeVersion('test'), '0.1.0');
    } finally {
      catalog.close();
    }
  });

  test('broken Worker candidate cannot replace active version', () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/CandidateTransactionWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      candidateHealthCheck: WorkerCandidateValidator(),
    );
    await store.installArchive(
      manifestInput: releaseManifest,
      archiveBytes: archiveBytes,
      expectedWorkerTypeId: 'test',
    );
    expect(await store.activeVersion('test'), '0.1.0');

    final brokenManifest = Map<String, Object?>.from(releaseManifest)
      ..['workerVersion'] = '0.1.1'
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(brokenManifest);
    await expectLater(
      store.installArchive(
        manifestInput: brokenManifest,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'test',
      ),
      throwsA(
        isA<WorkerCandidateValidationFailure>().having(
          (failure) => failure.issueCode,
          'issueCode',
          WorkerIssueCode.workerVersionMismatch,
        ),
      ),
    );
    expect(await store.activeVersion('test'), '0.1.0');
    expect(await store.lastKnownGoodVersion('test'), isNull);
    expect(await store.lastCandidateFailure('test'),
        containsPair('version', '0.1.1'));
    expect(
      (await store.lastCandidateFailure('test'))?['issueCode'],
      WorkerIssueCode.workerVersionMismatch,
    );
    await store.setUpdatePolicy('test', WorkerUpdatePolicy.automatic);
    var archiveReads = 0;
    final catalog = WorkerReleaseCatalog(
      cloudUri: Uri.parse('http://localhost'),
      store: store,
      releaseLoader: (workerTypeId, channel) async => [
        AvailableWorkerRelease(
          workerTypeId: workerTypeId,
          version: '0.1.1',
          platform: currentWorkerPlatform(),
          channel: channel,
          manifest: brokenManifest,
          publishedAt: null,
        ),
      ],
      archiveLoader: (_) async {
        archiveReads++;
        return archiveBytes;
      },
    );
    try {
      await catalog.refreshAutomaticUpdate('test');
    } finally {
      catalog.close();
    }
    expect(archiveReads, 0);
    expect(await store.activeVersion('test'), '0.1.0');
  });

  test('fake durable session survives fresh Worker processes', () async {
    Future<String> execute(String requestId, String assignmentId) async {
      final client =
          await _WorkerClient.start(workerExecutable, stateDirectory);
      try {
        await client.request(InitializeRequest(
          requestId: 'init-$requestId',
          workerTypeId: 'test',
          expectedWorkerVersion: '0.1.0',
        ));
        await client.write(ExecuteRequest(
          requestId: requestId,
          assignmentId: assignmentId,
          prompt: 'remember me',
          timeoutMs: 5000,
          sessionPolicy: WorkerSessionPolicy.durableSession,
          sessionKey: 'logical-session',
        ));
        while (true) {
          final frame = await client.nextFrame();
          if (frame is WorkerResult) return frame.output;
          if (frame is WorkerErrorFrame) fail('Worker error: ${frame.message}');
        }
      } finally {
        await client.dispose();
      }
    }

    expect(await execute('durable-1', 'assignment-1'),
        'echo: remember me (session run 1)');
    expect(await execute('durable-2', 'assignment-2'),
        'echo: remember me (session run 2)');
  });

  test('durable session continues after activating a newer Worker version',
      () async {
    final store = WorkerVersionStore(
      workersRoot: Directory('${scratch.path}/UpgradeSessionWorkers'),
      trustPolicy: signingFixture.trustPolicy,
      allowedPermissions: const {},
      platform: currentWorkerPlatform(),
      workerStateSchemaVersion: 1,
      candidateHealthCheck: WorkerCandidateValidator(),
    );
    await store.installArchive(
      manifestInput: releaseManifest,
      archiveBytes: archiveBytes,
      expectedWorkerTypeId: 'test',
    );

    Future<String> execute(String version, String requestId) async {
      final executable = await store.activeExecutable('test');
      expect(executable, isNotNull);
      expect(await store.activeVersion('test'), version);
      final result = await WorkerProcessSupervisor().execute(
        executable: executable!,
        workstreamDirectory: scratch,
        stateDirectory: store.stateDirectory('test'),
        workerTypeId: 'test',
        workerVersion: version,
        request: ExecuteRequest(
          requestId: requestId,
          assignmentId: 'assignment-$requestId',
          prompt: 'remember across upgrade',
          timeoutMs: 5000,
          sessionPolicy: WorkerSessionPolicy.durableSession,
          sessionKey: 'upgrade-session',
        ),
      );
      return result.result.output;
    }

    expect(
      await execute('0.1.0', 'before-upgrade'),
      'echo: remember across upgrade (session run 1)',
    );

    final upgradedPackage = Directory('${scratch.path}/upgrade-artifact');
    final executableName = 'test_worker${Platform.isWindows ? '.exe' : ''}';
    final binaryPath = '${upgradedPackage.path}${Platform.pathSeparator}'
        'bin${Platform.pathSeparator}$executableName';
    await Directory('${upgradedPackage.path}/bin').create(recursive: true);
    final compiled = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'exe',
        'bin/test_worker.dart',
        '--define=WORKER_VERSION=0.1.1',
        '-o',
        '${scratch.path}/compiled_test_worker_0_1_1',
      ],
      workingDirectory:
          '${Directory.current.parent.parent.path}${Platform.pathSeparator}workers${Platform.pathSeparator}test_worker',
    );
    expect(compiled.exitCode, 0,
        reason: '${compiled.stdout}\n${compiled.stderr}');
    await File('${scratch.path}/compiled_test_worker_0_1_1').copy(binaryPath);
    if (!Platform.isWindows) {
      final chmod = await Process.run('chmod', ['755', binaryPath]);
      expect(chmod.exitCode, 0, reason: chmod.stderr);
    }
    final upgradedArchive = await _archive(upgradedPackage);
    final upgradedManifest = Map<String, Object?>.from(releaseManifest)
      ..['workerVersion'] = '0.1.1'
      ..['packageDigest'] = await digestWorkerPackageDirectory(upgradedPackage)
      ..['archiveSha256'] = sha256.convert(upgradedArchive).toString()
      ..['signature'] = '';
    await signingFixture.signWorkerReleaseManifest(upgradedManifest);
    await store.installArchive(
      manifestInput: upgradedManifest,
      archiveBytes: upgradedArchive,
      expectedWorkerTypeId: 'test',
    );

    expect(await execute('0.1.1', 'after-upgrade'),
        'echo: remember across upgrade (session run 2)');
    final localSession = File(
      '${store.stateDirectory('test').path}${Platform.pathSeparator}'
      'upgrade-session.json',
    );
    expect(await localSession.exists(), isTrue);
    expect(
      localSession.absolute.path,
      startsWith(store.stateDirectory('test').absolute.path),
    );
    expect(
      await store.releaseStateFile('test').readAsString(),
      isNot(contains('providerSessionId')),
    );
    expect(
      await Directory('${store.versionDirectory('test', '0.1.0').path}'
              '${Platform.pathSeparator}state')
          .exists(),
      isFalse,
    );
    expect(
      await Directory('${store.versionDirectory('test', '0.1.1').path}'
              '${Platform.pathSeparator}state')
          .exists(),
      isFalse,
    );
  });

  test('Workspace process-tree termination cancels a running assignment',
      () async {
    final client = await _WorkerClient.start(workerExecutable, stateDirectory);
    await client.request(InitializeRequest(
      requestId: 'init-cancel',
      workerTypeId: 'test',
      expectedWorkerVersion: '0.1.0',
    ));
    await client.write(ExecuteRequest(
      requestId: 'execute-cancel',
      assignmentId: 'assignment-cancel',
      prompt: 'delay=30000;should not finish',
      timeoutMs: 60000,
      sessionPolicy: WorkerSessionPolicy.stateless,
    ));
    expect(await client.nextFrame(), isA<WorkerProgress>());

    await client.cancel();
    expect(await client.process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0));
    await client.dispose();
  });

  test('generic Worker supervisor cancellation kills its process tree',
      () async {
    final supervisor = WorkerProcessSupervisor();
    final assignment = ExecuteRequest(
      requestId: 'cancel-request',
      assignmentId: 'cancel-assignment',
      prompt: 'delay=10000;cancel me',
      timeoutMs: 15000,
      sessionPolicy: WorkerSessionPolicy.stateless,
    );
    final execution = supervisor.execute(
      executable: admission.executable,
      workstreamDirectory: scratch,
      stateDirectory: stateDirectory,
      workerTypeId: 'test',
      workerVersion: '0.1.0',
      request: assignment,
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await supervisor.cancel(assignment.assignmentId);
    await expectLater(
      execution,
      throwsA(
        isA<WorkerProcessFailure>().having(
          (failure) => failure.issueCode,
          'issueCode',
          WorkerIssueCode.cancelled,
        ),
      ),
    );
  });

  test('Worker deadline returns a stable timeout error', () async {
    final client = await _WorkerClient.start(workerExecutable, stateDirectory);
    await client.request(InitializeRequest(
      requestId: 'init-worker-timeout',
      workerTypeId: 'test',
      expectedWorkerVersion: '0.1.0',
    ));
    await client.write(ExecuteRequest(
      requestId: 'execute-worker-timeout',
      assignmentId: 'assignment-worker-timeout',
      prompt: 'delay=30000;too slow',
      timeoutMs: 50,
      sessionPolicy: WorkerSessionPolicy.stateless,
    ));
    expect(await client.nextFrame(), isA<WorkerProgress>());
    final timeout = await client.nextFrame() as WorkerErrorFrame;
    expect(timeout.code, WorkerIssueCode.deadlineExceeded);
    await client.dispose();
  });

  test('Workspace deadline terminates a Worker that exceeds assignment time',
      () async {
    final client = await _WorkerClient.start(workerExecutable, stateDirectory);
    await client.request(InitializeRequest(
      requestId: 'init-timeout',
      workerTypeId: 'test',
      expectedWorkerVersion: '0.1.0',
    ));
    await client.write(ExecuteRequest(
      requestId: 'execute-timeout',
      assignmentId: 'assignment-timeout',
      prompt: 'delay=30000;too slow',
      timeoutMs: 60000,
      sessionPolicy: WorkerSessionPolicy.stateless,
    ));
    expect(await client.nextFrame(), isA<WorkerProgress>());

    await client.enforceDeadline(const Duration(milliseconds: 80));
    await client.cancel();
    expect(await client.process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0));
    await client.dispose();
  });
}

class _RecordingPlatformRuntime implements PlatformRuntime {
  _RecordingPlatformRuntime(this.delegate);

  final PlatformRuntime delegate;
  Map<String, String> environment = const {};
  bool includeParentEnvironment = true;
  String? workingDirectory;

  @override
  String get operatingSystem => delegate.operatingSystem;
  @override
  bool get isWindows => delegate.isWindows;
  @override
  String get homeDirectory => delegate.homeDirectory;

  @override
  Future<void> restrictPermissions(String path, {required bool directory}) =>
      delegate.restrictPermissions(path, directory: directory);

  @override
  List<StreamSubscription<ProcessSignal>> watchTermination(
    void Function() onTermination,
  ) =>
      delegate.watchTermination(onTermination);

  @override
  Future<Process> startIsolatedProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
  }) {
    this.environment = Map.of(environment ?? const {});
    this.includeParentEnvironment = includeParentEnvironment;
    this.workingDirectory = workingDirectory;
    return delegate.startIsolatedProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
    );
  }

  @override
  Future<void> terminateProcessTree(Process process, {required bool force}) =>
      delegate.terminateProcessTree(process, force: force);
}

Future<List<int>> _archive(Directory packageRoot, {String? extraPath}) async {
  final archive = Archive();
  await for (final entity
      in packageRoot.list(recursive: true, followLinks: false)) {
    if (entity is! File) continue;
    final name = entity.path
        .substring(packageRoot.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    final entry = ArchiveFile.bytes(name, await entity.readAsBytes());
    entry.mode = (await entity.stat()).mode & 0x1ff;
    archive.addFile(entry);
  }
  if (extraPath != null) {
    archive.addFile(ArchiveFile.string(extraPath, 'unsafe'));
  }
  return Uint8List.fromList(
    GZipEncoder().encode(TarEncoder().encode(archive)),
  );
}

class _AcceptCandidateHealthCheck implements WorkerCandidateHealthCheck {
  @override
  Future<void> validate(
    WorkerReleaseAdmission admission, {
    required Directory stateDirectory,
  }) async {}
}

Future<({Map<String, Object?> manifest, List<int> archive})>
    _buildTestWorkerRelease({
  required Directory scratch,
  required Ed25519ReleaseFixture signingFixture,
  required Map<String, Object?> baseManifest,
  required String version,
  Map<String, Object?>? protocol,
  Map<String, Object?>? stateSchema,
  bool failPassiveProbe = false,
  bool crashOnStart = false,
  bool invalidExecutable = false,
}) async {
  final packageRoot = Directory(
    '${scratch.path}${Platform.pathSeparator}phase22-artifacts'
    '${Platform.pathSeparator}$version',
  );
  final executableName = 'test_worker${Platform.isWindows ? '.exe' : ''}';
  final executable = File(
    '${packageRoot.path}${Platform.pathSeparator}bin'
    '${Platform.pathSeparator}$executableName',
  );
  await executable.parent.create(recursive: true);
  if (invalidExecutable) {
    await executable.writeAsBytes(utf8.encode('not a native executable'));
  } else {
    final repository = Directory.current.parent.parent;
    final compileOutput = File(
      '${scratch.path}${Platform.pathSeparator}phase22-compiled-$version',
    );
    final defines = <String>['--define=WORKER_VERSION=$version'];
    if (failPassiveProbe) defines.add('--define=FAIL_PASSIVE_PROBE=true');
    if (crashOnStart) defines.add('--define=CRASH_ON_START=true');
    final compile = await Process.run(
      Platform.resolvedExecutable,
      [
        'compile',
        'exe',
        'bin/test_worker.dart',
        ...defines,
        '-o',
        compileOutput.path,
      ],
      workingDirectory: '${repository.path}/workers/test_worker',
    );
    if (compile.exitCode != 0) {
      throw StateError('test Worker compilation failed: '
          '${compile.stdout}\n${compile.stderr}');
    }
    await File(compileOutput.path).copy(executable.path);
  }
  if (!Platform.isWindows) {
    final chmod = await Process.run('chmod', ['755', executable.path]);
    if (chmod.exitCode != 0) {
      throw StateError(
          'could not mark test Worker executable: ${chmod.stderr}');
    }
  }

  final archive = await _archive(packageRoot);
  final manifest = Map<String, Object?>.from(baseManifest)
    ..['workerVersion'] = version
    ..['executable'] = 'bin/$executableName'
    ..['protocol'] = protocol ?? {'min': '3.0', 'max': '3.0'}
    ..['stateSchema'] = stateSchema ?? {'readMin': 1, 'readMax': 1, 'write': 1}
    ..['packageDigest'] = await digestWorkerPackageDirectory(packageRoot)
    ..['archiveSha256'] = sha256.convert(archive).toString()
    ..['signature'] = '';
  await signingFixture.signWorkerReleaseManifest(manifest);
  return (manifest: manifest, archive: archive);
}

class _WorkerClient {
  _WorkerClient(this.process)
      : _frames = StreamIterator<String>(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        ),
        _stderr = <String>[],
        _stderrDone = Completer<void>() {
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_stderr.add, onDone: _stderrDone.complete);
  }

  final Process process;
  final StreamIterator<String> _frames;
  final List<String> _stderr;
  final Completer<void> _stderrDone;
  Future<List<String>> get stderrLines async {
    await _stderrDone.future;
    return List.unmodifiable(_stderr);
  }

  static Future<_WorkerClient> start(
          String executable, Directory state) async =>
      _WorkerClient(await startIsolatedProcess(
        executable,
        const [],
        environment: {'CONCLAVE_WORKER_STATE_DIR': state.path},
      ));

  Future<void> write(WorkerFrame frame) async {
    process.stdin.writeln(frame.encode());
    await process.stdin.flush();
  }

  Future<WorkerFrame> request(WorkerFrame frame) async {
    await write(frame);
    return nextFrame();
  }

  Future<WorkerFrame> nextFrame() async {
    if (!await _frames.moveNext()) {
      throw StateError('Worker closed protocol output');
    }
    return decodeWorkerFrame(_frames.current);
  }

  Future<void> close() async {
    await process.stdin.close();
    await process.exitCode.timeout(const Duration(seconds: 5));
    await _stderrDone.future.timeout(const Duration(seconds: 5));
  }

  Future<void> enforceDeadline(Duration remaining) async {
    try {
      await process.exitCode.timeout(remaining);
    } on TimeoutException {
      await cancel();
    }
  }

  Future<void> cancel() => terminateProcessTree(process, force: true);

  Future<void> dispose() async {
    await cancel();
    await _frames.cancel();
  }
}
