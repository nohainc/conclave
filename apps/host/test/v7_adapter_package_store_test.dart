import 'dart:convert';

import 'package:archive/archive.dart';
import 'dart:io';

import 'package:conclave_host/configured_worker_registry.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'package:test/test.dart';
import 'support/ed25519_release_fixture.dart';
import 'support/compile_dart_executable.dart';

String get adapterExecutable =>
    'bin/adapter${Platform.isWindows ? '.exe' : ''}';

void main() {
  late Directory temp;
  late Directory source;
  late V7AdapterPackageStore store;
  late Ed25519ReleaseFixture fixture;
  final permissions = {
    WorkerPermission.readWorkspace,
    WorkerPermission.writeWorkspace,
    WorkerPermission.shell,
  };

  Future<void> writeAdapterProgram({bool healthy = true}) async {
    await File('${source.path}/bin/adapter.dart').writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  var adapterVersion = '';
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final base = {'protocolVersion': '1.0', 'requestId': request['requestId']};
    switch (request['type']) {
      case 'initialize.request': adapterVersion = request['adapterVersion'] as String; stdout.writeln(jsonEncode({...base, 'type': 'initialize.result', 'adapterVersion': adapterVersion, 'capabilities': <String>[] })); break;
      case 'version.request': stdout.writeln(jsonEncode({...base, 'type': 'version.result', 'adapterVersion': adapterVersion})); break;
      case 'health.request': stdout.writeln(jsonEncode({...base, 'type': 'health.result', 'healthy': $healthy})); break;
      default: stdout.writeln(jsonEncode({...base, 'type': 'error', 'code': 'unexpected', 'message': 'unexpected health request', 'retryable': false})); break;
    }
  }
}
''');
    await compileDartExecutable(
      File('${source.path}/bin/adapter.dart'),
      Directory('${source.path}/bin'),
      name: 'adapter',
    );
  }

  setUp(() async {
    fixture = await Ed25519ReleaseFixture.create(publisher: 'Conclave');
    temp = await Directory.systemTemp.createTemp('v7-package-store-');
    source = Directory('${temp.path}/source');
    await Directory('${source.path}/bin').create(recursive: true);
    await writeAdapterProgram();
    store = V7AdapterPackageStore(
      root: Directory('${temp.path}/installed'),
      trustPolicy: fixture.trustPolicy,
      allowedPermissions: permissions,
      platform: 'linux-x64',
    );
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<String> writeManifest(String version,
      {String releaseChannel = 'stable',
      String healthMode = 'protocol'}) async {
    final digest = await store.digestDirectory(source);
    final manifest = <String, Object?>{
      'workerTypeId': 'codex',
      'adapterVersion': version,
      'protocolVersion': '1.0',
      'publisher': 'Conclave',
      'displayName': 'Codex',
      'supportedPlatforms': ['linux-x64'],
      'capabilities': ['code'],
      'permissions': ['workspace:read', 'shell:execute'],
      'authStrategies': ['api_key'],
      'modelSelectionMode': 'allow_list',
      'prerequisites': <Object>[],
      'executable': adapterExecutable,
      'launchArgs': [],
      'secretRequirements': [
        {
          'name': 'provider-key',
          'authStrategy': 'api_key',
          'environmentVariable': 'PROVIDER_API_KEY',
          'required': true,
          'description': 'Provider API key',
        }
      ],
      'healthCheck': {'mode': healthMode, 'timeoutMs': 5000},
      'packageDigest': digest,
      'signingKeyId': fixtureKeyId,
      'signature': '',
      'releaseChannel': releaseChannel,
    };
    await fixture.signAdapterManifest(manifest, digest, publisher: 'Conclave');
    await File('${source.path}/manifest.json')
        .writeAsString(jsonEncode(manifest));
    return digest;
  }

  LocalConfiguredWorker localWorker({
    String id = 'local-worker-1',
    String name = 'Codex Work',
    String? credentialRef,
    String version = 'stable',
  }) =>
      LocalConfiguredWorker(
        id: id,
        workspaceId: 'workspace-1',
        name: name,
        workerTypeId: 'codex',
        authStrategy: 'api_key',
        credentialRef: credentialRef ?? 'worker-credential/$id',
        defaultModel: 'gpt-5.5',
        adapterConfig: const {'temperature': 0.2},
        allowedModels: const ['gpt-5.5'],
        localPermissions: const ['workspace:read', 'shell:execute'],
        localConcurrencyLimit: 2,
        adapterVersionPolicy: version,
        status: LocalWorkerStatus.ready,
        credentialStatus: LocalWorkerCredentialStatus.ready,
        revision: 1,
        createdAt: '2026-09-26T00:00:00.000Z',
        updatedAt: '2026-09-26T00:00:00.000Z',
      );

  Future<List<int>> packSource({String? extraPath}) async {
    final archive = Archive();
    await for (final entity
        in source.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path
          .substring(source.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      final entry = ArchiveFile.bytes(name, await entity.readAsBytes());
      entry.mode = (await entity.stat()).mode & 0x1ff;
      archive.addFile(entry);
    }
    if (extraPath != null) {
      archive.addFile(ArchiveFile.string(extraPath, 'unsafe'));
    }
    return GZipEncoder().encode(TarEncoder().encode(archive));
  }

  test('installs a signed adapter from a bounded gzip tar archive', () async {
    await writeManifest('1.2.3');
    final installed =
        await store.installArchive(archiveBytes: await packSource());
    expect(
        await File(
                '${installed.path}${Platform.pathSeparator}$adapterExecutable')
            .exists(),
        isTrue);
    expect(await store.hasVerifiedActivePackage('codex'), isTrue);
    expect(
      await store.hasVerifiedActivePackage('codex', ['workstream_filesystem']),
      isFalse,
    );
    expect(
      await store.hasVerifiedActivePackage(
          'codex', ['workstream_filesystem', 'shell_execution']),
      isTrue,
    );
    expect(
        await File(
                '${installed.path}${Platform.pathSeparator}$adapterExecutable')
            .stat()
            .then((s) => s.mode & 0x49),
        isNonZero);
    expect(
        (await store.resolve(
          worker: localWorker(),
          readCredential: (_) => 'private-api-key',
        ))
            ?.adapterVersion,
        '1.2.3');
  });

  test('does not report a missing or untrusted adapter as usable', () async {
    expect(await store.hasVerifiedActivePackage('codex'), isFalse);
    expect(await store.hasVerifiedActivePackage('../codex'), isFalse);
  });

  test('rejects archive path traversal before extraction', () async {
    await writeManifest('1.2.3');
    await expectLater(
      store.installArchive(
          archiveBytes: await packSource(extraPath: '../escape')),
      throwsStateError,
    );
    expect(await File('${temp.path}/escape').exists(), isFalse);
  });

  test('rejects archive whose manifest differs from catalog metadata',
      () async {
    await writeManifest('1.2.3');
    await expectLater(
      store.installArchive(
        archiveBytes: await packSource(),
        expectedManifest: const {'workerTypeId': 'other-adapter'},
      ),
      throwsStateError,
    );
    expect(await store.hasVerifiedActivePackage('codex'), isFalse);
  });

  test(
      'installs, activates, and resolves a signed adapter with local secret scope',
      () async {
    await writeManifest('1.2.3');
    final installed = await store.install(sourceDirectory: source);
    expect(await installed.exists(), isTrue);
    final launch = await store.resolve(
      worker: localWorker(),
      readCredential: (key) =>
          key == 'worker-credential/local-worker-1' ? 'private-api-key' : null,
    );
    expect(launch, isNotNull);
    expect(launch!.adapterVersion, '1.2.3');
    expect(
      launch.processSpec.executable,
      endsWith('${Platform.pathSeparator}bin${Platform.pathSeparator}adapter'),
    );
    expect(launch.processSpec.environment,
        {'PROVIDER_API_KEY': 'private-api-key'});
    expect(launch.processSpec.secretValues, {'private-api-key'});
    expect(launch.allowedModels, {'gpt-5.5'});
  });

  test('rejects modified installed package before assignment resolution',
      () async {
    await writeManifest('1.2.3');
    final installed = await store.install(sourceDirectory: source);
    await File('${installed.path}${Platform.pathSeparator}$adapterExecutable')
        .writeAsString('tampered');
    await expectLater(
      store.resolve(
        worker: localWorker(),
        readCredential: (_) => 'private-api-key',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects package permissions beyond the local Worker grant', () async {
    await writeManifest('1.2.3');
    await store.install(sourceDirectory: source);
    final worker = localWorker().copyWith(
      localPermissions: const ['workspace:read'],
    );
    await expectLater(
      store.resolve(worker: worker, readCredential: (_) => 'private-api-key'),
      throwsStateError,
    );
  });

  test('new verified version atomically becomes active', () async {
    await writeManifest('1.2.3');
    await store.install(sourceDirectory: source);
    await File('${source.path}/version.txt').writeAsString('two');
    await writeManifest('1.3.0');
    await store.install(sourceDirectory: source);
    final launch = await store.resolve(
      worker: localWorker(),
      readCredential: (_) => 'private-api-key',
    );
    expect(launch?.adapterVersion, '1.3.0');
  });

  test('failed staged health check leaves the prior version active', () async {
    await writeManifest('1.2.3');
    await store.install(sourceDirectory: source);
    await writeAdapterProgram(healthy: false);
    await writeManifest('1.3.0');
    await expectLater(
      store.install(sourceDirectory: source),
      throwsStateError,
    );
    final launch = await store.resolve(
      worker: localWorker(),
      readCredential: (_) => 'private-api-key',
    );
    expect(launch?.adapterVersion, '1.2.3');
  });

  test('rollback re-verifies and health-checks before changing activation',
      () async {
    await writeManifest('1.2.3');
    await store.install(sourceDirectory: source);
    await File('${source.path}/version.txt').writeAsString('two');
    await writeManifest('1.3.0');
    await store.install(sourceDirectory: source);
    await store.rollback(workerTypeId: 'codex', version: '1.2.3');
    final launch = await store.resolve(
      worker: localWorker(),
      readCredential: (_) => 'private-api-key',
    );
    expect(launch?.adapterVersion, '1.2.3');
  });

  test('process-exit health mode waits for a clean adapter shutdown', () async {
    await writeManifest('1.2.3', healthMode: 'process_exit');
    final installed = await store.install(sourceDirectory: source);
    expect(await installed.exists(), isTrue);
  });

  test('stable Worker policy rejects a signed beta adapter', () async {
    await writeManifest('1.2.3', releaseChannel: 'beta');
    await store.install(sourceDirectory: source);
    await expectLater(
      store.resolve(
        worker: localWorker(version: 'stable'),
        readCredential: (_) => 'private-api-key',
      ),
      throwsStateError,
    );
  });

  test(
      'one installed adapter release serves multiple configured workers of the same type',
      () async {
    await writeManifest('1.2.3');
    await store.install(sourceDirectory: source);

    final workerA = localWorker(
      id: 'worker-a',
      name: 'Codex Personal',
      credentialRef: 'worker-credential/worker-a',
    );
    final workerB = localWorker(
      id: 'worker-b',
      name: 'Codex Work',
      credentialRef: 'worker-credential/worker-b',
    ).copyWith(
      defaultModel: 'o3-mini',
      allowedModels: const ['o3-mini', 'gpt-5.5'],
    );

    final launchA = await store.resolve(
      worker: workerA,
      readCredential: (key) =>
          key == 'worker-credential/worker-a' ? 'secret-a' : null,
    );
    final launchB = await store.resolve(
      worker: workerB,
      readCredential: (key) =>
          key == 'worker-credential/worker-b' ? 'secret-b' : null,
    );

    expect(launchA?.processSpec.executable, launchB?.processSpec.executable);
    expect(
      launchA?.processSpec.executable,
      endsWith(
          '${Platform.pathSeparator}codex${Platform.pathSeparator}1.2.3${Platform.pathSeparator}bin${Platform.pathSeparator}adapter'),
    );
    expect(launchA?.processSpec.environment['PROVIDER_API_KEY'], 'secret-a');

    expect(launchB?.processSpec.environment['PROVIDER_API_KEY'], 'secret-b');
    expect(launchA?.allowedModels, {'gpt-5.5'});
    expect(launchB?.allowedModels, {'o3-mini', 'gpt-5.5'});
  });
}
