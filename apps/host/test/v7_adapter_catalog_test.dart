import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'package:conclave_host/v7_adapter_catalog.dart';
import 'package:conclave_host/v7_adapter_package_store.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'support/ed25519_release_fixture.dart';

void main() {
  late Directory temp;
  late Directory packageSource;
  late V7AdapterPackageStore store;
  late WorkerTrustPolicy trustPolicy;
  late String platform;
  late Ed25519ReleaseFixture fixture;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('v7-adapter-catalog-');
    packageSource = Directory('${temp.path}/package');
    await Directory('${packageSource.path}/bin').create(recursive: true);
    fixture = await Ed25519ReleaseFixture.create(publisher: 'conclave');
    trustPolicy = fixture.trustPolicy;
    final os = switch (Platform.operatingSystem) {
      'macos' => 'macos',
      'linux' => 'linux',
      'windows' => 'windows',
      _ => fail('unsupported test platform'),
    };
    final arch =
        Platform.version.toLowerCase().contains('arm64') ? 'arm64' : 'x64';
    platform = '$os-$arch';
    store = V7AdapterPackageStore(
      root: Directory('${temp.path}/installed'),
      trustPolicy: trustPolicy,
      allowedPermissions: WorkerPermission.values.toSet(),
      platform: platform,
    );
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('fetches, hash-checks, binds, and admits a catalog release', () async {
    await File('${packageSource.path}/bin/adapter.dart').writeAsString('''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  var version = '';
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map<String, dynamic>;
    final base = {'protocolVersion': '1.0', 'requestId': request['requestId']};
    switch (request['type']) {
      case 'initialize.request':
        version = request['adapterVersion'] as String;
        stdout.writeln(jsonEncode({...base, 'type': 'initialize.result', 'adapterVersion': version, 'capabilities': <String>[]}));
      case 'version.request':
        stdout.writeln(jsonEncode({...base, 'type': 'version.result', 'adapterVersion': version}));
      case 'health.request':
        stdout.writeln(jsonEncode({...base, 'type': 'health.result', 'healthy': true}));
    }
  }
}
''');
    final launcher = File('${packageSource.path}/bin/adapter');
    await launcher.writeAsString(
      r'''#!/bin/sh
exec dart "$(dirname "$0")/adapter.dart"
''',
    );
    final chmod = await Process.run('chmod', ['700', launcher.path]);
    expect(chmod.exitCode, 0);

    final digest = await store.digestDirectory(packageSource);
    final manifest = <String, Object?>{
      'workerTypeId': 'codex',
      'adapterVersion': '1.0.0',
      'protocolVersion': '1.0',
      'publisher': 'conclave',
      'displayName': 'Codex',
      'supportedPlatforms': [platform],
      'capabilities': ['code'],
      'permissions': <String>[],
      'authStrategies': ['browser_auth'],
      'modelSelectionMode': 'allow_list',
      'prerequisites': <Object>[],
      'executable': 'bin/adapter',
      'launchArgs': <String>[],
      'secretRequirements': <Object>[],
      'healthCheck': {'mode': 'protocol', 'timeoutMs': 5000},
      'packageDigest': digest,
      'signingKeyId': fixtureKeyId,
      'signature': '',
      'releaseChannel': 'stable',
    };
    await fixture.signAdapterManifest(manifest, digest, publisher: 'conclave');
    await File('${packageSource.path}/manifest.json')
        .writeAsString(jsonEncode(manifest));

    final archive = Archive();
    await for (final entity
        in packageSource.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.path.substring(packageSource.path.length + 1);
      final entry = ArchiveFile.bytes(name, await entity.readAsBytes());
      entry.mode = (await entity.stat()).mode & 0x1ff;
      archive.addFile(entry);
    }
    final archiveBytes = GZipEncoder().encode(TarEncoder().encode(archive));
    final archiveSha256 = sha256.convert(archiveBytes).toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serving = server.forEach((request) async {
      if (request.uri.path == '/api/v7/adapters') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'releases': [
            {
              'workerTypeId': 'codex',
              'version': '1.0.0',
              'channel': 'stable',
              'protocolVersion': '1.0',
              'supportedPlatforms': [platform],
              'manifest': manifest,
              'packageDigest': digest,
              'archiveSha256': archiveSha256,
            }
          ]
        }));
      } else if (request.uri.path.endsWith('/download')) {
        request.response.headers
          ..set('x-conclave-archive-sha256', archiveSha256)
          ..set('x-conclave-package-digest', digest)
          ..contentType = ContentType('application', 'gzip');
        request.response.add(archiveBytes);
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });

    final client = V7AdapterCatalogClient(
      cloudUri: Uri(
        scheme: 'http',
        host: server.address.address,
        port: server.port,
      ),
      packageStore: store,
    );
    try {
      final installed = await client.installLatest('codex');
      expect(installed, isNotNull);
      expect(await store.hasVerifiedActivePackage('codex'), isTrue);
    } finally {
      client.close();
      await server.close(force: true);
      await serving;
    }
  });
}
