import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:conclave_host/platform_runtime.dart';
import 'package:conclave_host/worker_candidate_validator.dart';
import 'package:conclave_host/worker_diagnostic_store.dart';
import 'package:conclave_host/worker_process_supervisor.dart';
import 'package:conclave_host/worker_release_manifest.dart';
import 'package:conclave_host/worker_release_verifier.dart';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  test('a development catalog Worker owns its CLI integration', () async {
    final repository = Directory.current.parent.parent;
    final catalog = jsonDecode(
      await File('${repository.path}/workers/development_catalog.json')
          .readAsString(),
    ) as Map<String, Object?>;
    expect(catalog['schemaVersion'], 1);
    final entries = catalog['entries']! as List;
    final fixtureEntry = entries
        .cast<Map>()
        .singleWhere((entry) => entry['workerTypeId'] == 'fixture_cli');
    expect(fixtureEntry['developmentOnly'], isTrue);
    expect(fixtureEntry['productCatalog'], isFalse);

    final scratch =
        await Directory.systemTemp.createTemp('conclave-third-worker-');
    try {
      final source = Directory('${repository.path}/workers/fixture_cli');
      final packageRoot = Directory('${scratch.path}/artifact');
      final bin = Directory('${packageRoot.path}/bin');
      await bin.create(recursive: true);
      final workerName = 'conclave-fixture-cli-worker'
          '${Platform.isWindows ? '.exe' : ''}';
      final providerName =
          'fixture-provider${Platform.isWindows ? '.exe' : ''}';
      final workerPath = '${bin.path}${Platform.pathSeparator}$workerName';
      final providerPath = '${bin.path}${Platform.pathSeparator}$providerName';

      await _compile(
        source: source,
        entrypoint: 'bin/fixture_cli_worker.dart',
        output: workerPath,
      );
      await _compile(
        source: source,
        entrypoint: 'tool/fixture_provider.dart',
        output: providerPath,
      );
      if (!Platform.isWindows) {
        for (final path in [workerPath, providerPath]) {
          final chmod = await Process.run('chmod', ['755', path]);
          expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
        }
      }

      final archiveBytes = _archive(packageRoot);
      final signingFixture = await Ed25519ReleaseFixture.create();
      final manifest = <String, Object?>{
        'manifestVersion': workerReleaseManifestVersion,
        'workerTypeId': 'fixture_cli',
        'workerVersion': '0.1.0',
        'publisher': fixturePublisher,
        'platform': currentWorkerPlatform(),
        'protocol': {'min': '3.0', 'max': '3.0'},
        'stateSchema': {'readMin': 1, 'readMax': 1, 'write': 1},
        'capabilities': ['initialize', 'probe', 'execute'],
        'permissions': <String>[],
        'executable': 'bin/$workerName',
        'releaseChannel': 'development',
        'packageDigest': await digestWorkerPackageDirectory(packageRoot),
        'archiveSha256': sha256.convert(archiveBytes).toString(),
        'signingKeyId': fixtureKeyId,
        'signature': '',
      };
      await signingFixture.signWorkerReleaseManifest(manifest);
      final admission = await WorkerReleaseVerifier.verify(
        manifestInput: manifest,
        packageRoot: packageRoot,
        archiveBytes: archiveBytes,
        expectedWorkerTypeId: 'fixture_cli',
        platform: currentWorkerPlatform(),
        trustPolicy: signingFixture.trustPolicy,
        allowedPermissions: const {},
        readableStateSchemaVersion: 1,
      );
      expect(admission.manifest.workerTypeId, 'fixture_cli');

      final state = Directory('${scratch.path}/Workers/fixture_cli/state');
      await WorkerCandidateValidator().validate(
        admission,
        stateDirectory: state,
      );
      final progress = <WorkerProgress>[];
      final result = await WorkerProcessSupervisor().execute(
        executable: admission.executable,
        workstreamDirectory: scratch,
        stateDirectory: state,
        workerTypeId: 'fixture_cli',
        workerVersion: '0.1.0',
        request: ExecuteRequest(
          requestId: 'fixture-request',
          assignmentId: 'fixture-assignment',
          prompt: 'third package works',
          timeoutMs: 5000,
          sessionPolicy: WorkerSessionPolicy.stateless,
        ),
        onProgress: progress.add,
      );
      expect(result.result.output, 'fixture echo: third package works');
      expect(progress, hasLength(2));

      final report = await WorkerDiagnosticStore(
        directory: Directory('${state.parent.path}/logs'),
      ).createCopyableReport();
      expect(report, contains('fixture_cli'));
      expect(report, contains('0.3.0'));
    } finally {
      if (await scratch.exists()) await scratch.delete(recursive: true);
    }
  });
}

Future<void> _compile({
  required Directory source,
  required String entrypoint,
  required String output,
}) async {
  final compiled = await Process.run(
    Platform.resolvedExecutable,
    ['compile', 'exe', entrypoint, '-o', output],
    workingDirectory: source.path,
  );
  expect(compiled.exitCode, 0,
      reason: '${compiled.stdout}\n${compiled.stderr}');
}

List<int> _archive(Directory root) {
  final archive = Archive();
  for (final entity in root.listSync(recursive: true).whereType<File>()) {
    final name = entity.path
        .substring(root.path.length + 1)
        .replaceAll(Platform.pathSeparator, '/');
    final entry = ArchiveFile.bytes(name, entity.readAsBytesSync());
    entry.mode = entity.statSync().mode & 0x1ff;
    archive.addFile(entry);
  }
  return Uint8List.fromList(
    GZipEncoder().encode(TarEncoder().encode(archive)),
  );
}
