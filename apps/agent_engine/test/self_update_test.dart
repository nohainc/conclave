import 'dart:convert';
import 'dart:io';
import 'package:conclave_agent_engine/self_update.dart';
import 'package:crypto/crypto.dart';
import 'package:conclave_agent_engine/trust_policy.dart';
import 'package:test/test.dart';

void main() {
  test('fetches authenticated release metadata and bounded package bytes',
      () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final packageBytes = [11, 22, 33];
    final digest = sha256.convert(packageBytes).toString();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) {
      expect(request.headers.value(HttpHeaders.authorizationHeader),
          'Bearer agent-token');
      if (request.uri.path.endsWith('/latest')) {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'updateAvailable': true,
            'release': {
              'version': '5.0.0',
              'channel': 'stable',
              'packageDigest': digest,
              'packageR2Key': 'agent/5.0.0.tar.gz',
              'publisher': 'conclave',
              'signature': 'sig-test',
            },
          }));
      } else {
        request.response.add(packageBytes);
      }
      request.response.close();
    });
    try {
      final client = const AgentReleaseClient();
      final base = Uri.http('127.0.0.1:${server.port}', '/');
      final release = await client.latest(
        cloudUri: base,
        channel: 'stable',
        currentVersion: '4.0.0',
        authToken: 'agent-token',
      );
      expect(release?.version, '5.0.0');
      final package = await client.download(
        cloudUri: base,
        release: release!,
        authToken: 'agent-token',
      );
      expect(package.bytes, packageBytes);
      await expectLater(
        client.download(
          cloudUri: base,
          release: release,
          authToken: 'agent-token',
          maxPackageBytes: 2,
        ),
        throwsA(predicate(
            (error) => error.toString().contains('exceeded 2 bytes'))),
      );
    } finally {
      await subscription.cancel();
      await server.close(force: true);
      await root.delete(recursive: true);
    }
  });

  test('activates a verified release and records metadata', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [1, 2, 3];
    await AgentUpdater(root, requireSignature: false).apply(
      ReleasePackage(
          version: '1.1.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString()),
      healthCheck: (_) async => true,
    );
    expect(await File('${root.path}/agent.active').exists(), isTrue);
    expect(await File('${root.path}/release.json').readAsString(),
        contains('1.1.0'));
    await root.delete(recursive: true);
  });

  test('restores previous release after a failed health check', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    await root.create(recursive: true);
    final old = File('${root.path}/agent.active')..writeAsBytesSync([9]);
    final bytes = [1, 2, 3];
    await expectLater(
      AgentUpdater(root, requireSignature: false).apply(
        ReleasePackage(
            version: '2.0.0',
            channel: 'beta',
            bytes: bytes,
            digest: sha256.convert(bytes).toString()),
        healthCheck: (_) async => false,
      ),
      throwsStateError,
    );
    expect(await old.readAsBytes(), [9]);
    await root.delete(recursive: true);
  });

  test('rejects an invalid signed release', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [4, 5, 6];
    const policy = PluginTrustPolicy(trustedSecrets: {'release': 'root'});
    await expectLater(
      AgentUpdater(root, trustPolicy: policy).apply(
        ReleasePackage(
          version: '1.2.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
          publisher: 'release',
          signature: 'invalid',
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    await root.delete(recursive: true);
  });

  test('rejects an unsigned release by default', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [6, 7, 8];
    await expectLater(
      AgentUpdater(root).apply(
        ReleasePackage(
          version: '1.3.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(predicate((error) => error
          .toString()
          .contains('signature verification is not configured'))),
    );
    await root.delete(recursive: true);
  });

  test('rejects a release requiring a newer protocol', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [7, 8, 9];
    await expectLater(
      AgentUpdater(root, currentProtocolVersion: '2.0', requireSignature: false)
          .apply(
        ReleasePackage(
          version: '2.0.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
          minimumProtocolVersion: '3.0',
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    await root.delete(recursive: true);
  });

  test('rejects a signed or valid release downgrade', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final currentBytes = [1, 1, 1];
    final currentDigest = sha256.convert(currentBytes).toString();
    await AgentUpdater(root, requireSignature: false).apply(
      ReleasePackage(
        version: '2.0.0',
        channel: 'stable',
        bytes: currentBytes,
        digest: currentDigest,
      ),
      healthCheck: (_) async => true,
    );

    final olderBytes = [0, 0, 1];
    await expectLater(
      AgentUpdater(root, requireSignature: false).apply(
        ReleasePackage(
          version: '1.9.9',
          channel: 'stable',
          bytes: olderBytes,
          digest: sha256.convert(olderBytes).toString(),
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await File('${root.path}/agent.active').readAsBytes(), currentBytes);
    await root.delete(recursive: true);
  });

  test('keeps release versions immutable and records provenance', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [2, 4, 6];
    final digest = sha256.convert(bytes).toString();
    final package = ReleasePackage(
      version: '3.0.0',
      channel: 'stable',
      bytes: bytes,
      digest: digest,
      operatingSystem: 'macos',
      architecture: 'arm64',
      releaseNotes: 'Security update',
      packageUrl: 'https://example.test/agent.tgz',
    );
    await AgentUpdater(root, requireSignature: false)
        .apply(package, healthCheck: (_) async => true);
    await AgentUpdater(root, requireSignature: false)
        .apply(package, healthCheck: (_) async => false);
    expect(await File('${root.path}/agent.active').readAsBytes(), bytes);
    final metadata =
        jsonDecode(await File('${root.path}/release.json').readAsString())
            as Map<String, dynamic>;
    expect(metadata['operatingSystem'], 'macos');
    expect(metadata['architecture'], 'arm64');
    expect(metadata['releaseNotes'], 'Security update');

    final different = [2, 4, 7];
    await expectLater(
      AgentUpdater(root, requireSignature: false).apply(
        ReleasePackage(
          version: '3.0.0',
          channel: 'stable',
          bytes: different,
          digest: sha256.convert(different).toString(),
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    await root.delete(recursive: true);
  });

  test('rejects malformed release versions before staging', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [8];
    await expectLater(
      AgentUpdater(root, requireSignature: false).apply(
        ReleasePackage(
          version: '../escape',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
        ),
        healthCheck: (_) async => true,
      ),
      throwsA(isA<StateError>()),
    );
    expect((await root.list().toList()), isEmpty);
    await root.delete(recursive: true);
  });

  test('rejects oversized release packages before staging', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [1, 2, 3, 4];
    await expectLater(
      AgentUpdater(root, requireSignature: false).apply(
        ReleasePackage(
          version: '4.0.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
        ),
        maxPackageBytes: 3,
        healthCheck: (_) async => true,
      ),
      throwsA(predicate((error) =>
          error.toString().contains('exceeds the 3 byte package limit'))),
    );
    expect((await root.list().toList()), isEmpty);
    await root.delete(recursive: true);
  });

  test('does not stage an update while assignments are active', () async {
    final root = await Directory.systemTemp.createTemp('conclave-update-');
    final bytes = [10, 11, 12];
    await expectLater(
      AgentUpdater(root, requireSignature: false).apply(
        ReleasePackage(
          version: '4.0.0',
          channel: 'stable',
          bytes: bytes,
          digest: sha256.convert(bytes).toString(),
        ),
        hasActiveAssignments: () async => true,
        healthCheck: (_) async => true,
      ),
      throwsA(predicate((error) =>
          error.toString().contains('waiting for active assignments'))),
    );
    expect(await root.list().toList(), isEmpty);
    await root.delete(recursive: true);
  });
}
