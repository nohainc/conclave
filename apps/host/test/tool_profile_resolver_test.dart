import 'dart:convert';
import 'dart:io';

import 'package:conclave_host/tool_profile_release_store.dart';
import 'package:conclave_host/tool_profile_resolver.dart';
import 'package:test/test.dart';

import 'support/ed25519_release_fixture.dart';

void main() {
  late Ed25519ReleaseFixture signing;
  late Directory temporary;
  late ToolProfileReleaseStore store;
  late Map<String, Object?> profile;
  late ToolProfileResolver resolver;

  setUp(() async {
    signing = await Ed25519ReleaseFixture.create();
    temporary = await Directory.systemTemp.createTemp('conclave-resolver-');
    store = ToolProfileReleaseStore(
      profilesRoot: Directory('${temporary.path}/Profiles'),
      trustPolicy: signing.trustPolicy,
    );
    resolver = ToolProfileResolver(store);
    profile = jsonDecode(
      File('../../packages/tool-profile/test/fixtures/fixture-cli.v1.json')
          .readAsStringSync(),
    ) as Map<String, Object?>;
  });

  tearDown(() async => temporary.delete(recursive: true));

  Future<Map<String, Object?>> installRelease(
    int version, {
    required String minProvider,
    required String maxProvider,
  }) async {
    final releaseProfile =
        jsonDecode(jsonEncode(profile)) as Map<String, Object?>;
    releaseProfile['releaseVersion'] = version;
    (releaseProfile['providerTool']!
        as Map<String, Object?>)['supportedVersions'] = [
      {'min': minProvider, 'maxExclusive': maxProvider},
    ];
    final release = <String, Object?>{
      'profileDefinitionId': 'fixture-cli',
      'workerTypeId': 'fixture-worker',
      'displayName': 'Fixture CLI',
      'providerToolName': 'Fixture CLI',
      'channel': 'stable',
      'releaseVersion': version,
      'profile': releaseProfile,
      'schemaVersion': releaseProfile['schemaVersion'],
      'engineFamily': releaseProfile['engineFamily'],
      'engineCompatibility': releaseProfile['engineCompatibility'],
    };
    await signing.signToolProfileRelease(release);
    await store.installRelease(
      releaseInput: release,
      expectedWorkerTypeId: 'fixture-worker',
    );
    await store.activateVersion(
      'fixture-cli',
      release['releaseVersion']! as int,
      selectAsStable: true,
    );
    return release;
  }

  Future<ToolProfileResolution> resolve(String providerVersion) =>
      resolver.resolve(
        logicalWorkerTypeId: 'fixture-worker',
        profileDefinitionId: 'fixture-cli',
        engineVersion: '1.5.0',
        providerCliVersion: providerVersion,
      );

  test('selects active compatible release for old and new CLI versions',
      () async {
    await installRelease(1, minProvider: '1.0.0', maxProvider: '2.0.0');
    await installRelease(2, minProvider: '2.0.0', maxProvider: '4.0.0');

    final oldCli = await resolve('1.9.9');
    expect(oldCli.source, ToolProfileResolutionSource.lastKnownGood);
    expect(oldCli.release?.releaseVersion, 1);

    final newCli = await resolve('3.2.1');
    expect(newCli.source, ToolProfileResolutionSource.active);
    expect(newCli.release?.releaseVersion, 2);
  });

  test('fails closed when no release supports the installed CLI version',
      () async {
    await installRelease(1, minProvider: '1.0.0', maxProvider: '2.0.0');
    await installRelease(2, minProvider: '2.0.0', maxProvider: '4.0.0');

    final result = await resolve('9.0.0');
    expect(result.source, ToolProfileResolutionSource.unavailable);
    expect(result.release, isNull);
    expect(
      result.reason,
      ToolProfileUnavailableReason.unsupportedProviderVersion,
    );
  });

  test('falls through to the current stable selection after active fails',
      () async {
    await installRelease(1, minProvider: '1.0.0', maxProvider: '2.0.0');
    await installRelease(2, minProvider: '2.0.0', maxProvider: '4.0.0');
    await store.rollbackToLastKnownGood(
      'fixture-cli',
      candidateValidator: (_) async => true,
    );

    final result = await resolve('3.0.0');
    expect(result.source, ToolProfileResolutionSource.stable);
    expect(result.release?.releaseVersion, 2);
  });

  test(
      'uses stable Profile as a version-probe bootstrap before final resolution',
      () async {
    await installRelease(1, minProvider: '1.0.0', maxProvider: '2.0.0');
    await installRelease(2, minProvider: '4.0.0', maxProvider: '5.0.0');

    final bootstrap = await resolver.resolveBootstrapProfile(
      logicalWorkerTypeId: 'fixture-worker',
      profileDefinitionId: 'fixture-cli',
      engineVersion: '1.5.0',
    );
    expect(bootstrap.source, ToolProfileResolutionSource.active);
    expect(bootstrap.release?.releaseVersion, 2);

    final finalResolution = await resolve('1.8.0');
    expect(finalResolution.source, ToolProfileResolutionSource.lastKnownGood);
    expect(finalResolution.release?.releaseVersion, 1);
  });
}
