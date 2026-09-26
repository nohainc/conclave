import 'dart:io';

import 'package:test/test.dart';
import 'package:conclave_host/v7_adapter_admission.dart';
import 'package:conclave_host/worker_trust_policy.dart';
import 'support/ed25519_release_fixture.dart';

void main() {
  late Directory root;
  final digest = 'a' * 64;
  late Ed25519ReleaseFixture fixture;

  Future<Map<String, Object?>> manifest(String executable) async {
    final value = <String, Object?>{
      'workerTypeId': 'codex',
      'adapterVersion': '1.2.3',
      'protocolVersion': '1.0',
      'publisher': 'Conclave',
      'displayName': 'Codex',
      'supportedPlatforms': ['linux-x64'],
      'capabilities': ['code'],
      'permissions': ['workspace:read', 'shell:execute'],
      'authStrategies': ['browser_auth'],
      'modelSelectionMode': 'allow_list',
      'prerequisites': <Object?>[],
      'executable': executable,
      'launchArgs': ['--stdio'],
      'secretRequirements': [
        {
          'name': 'provider-token',
          'authStrategy': 'browser_auth',
          'environmentVariable': 'PROVIDER_TOKEN',
          'required': true,
          'description': 'Local provider session',
        }
      ],
      'healthCheck': {'mode': 'protocol', 'timeoutMs': 5000},
      'packageDigest': digest,
      'signingKeyId': fixtureKeyId,
      'signature': '',
      'releaseChannel': 'stable',
    };
    await fixture.signAdapterManifest(value, digest, publisher: 'Conclave');
    return value;
  }

  setUp(() async {
    fixture = await Ed25519ReleaseFixture.create(publisher: 'Conclave');
    root = await Directory.systemTemp.createTemp('conclave-v7-adapter-');
    await Directory('${root.path}/bin').create();
    await File('${root.path}/bin/adapter').writeAsString('#!/bin/false');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('admits trusted package and produces a scoped executor spec', () async {
    final admitted = await V7AdapterAdmission.admit(
      input: await manifest('bin/adapter'),
      packageRoot: root,
      expectedWorkerTypeId: 'codex',
      verifiedPackageDigest: digest,
      platform: 'linux-x64',
      trustPolicy: fixture.trustPolicy,
      allowedPermissions: WorkerPermission.values.toSet(),
    );
    final spec = admitted.createProcessSpec(
      workerId: 'worker-1',
      workingDirectory: '/tmp/workstream',
      localConcurrencyLimit: 2,
      availableSecrets: {'provider-token': 'private-token'},
    );
    expect(spec.executable, endsWith('/bin/adapter'));
    expect(spec.workingDirectory, '/tmp/workstream');
    expect(spec.environment, {'PROVIDER_TOKEN': 'private-token'});
    expect(spec.allowedEnvironmentVariables, {'PROVIDER_TOKEN'});
    expect(spec.secretValues, {'private-token'});
    expect(spec.maxConcurrentAssignments, 2);
  });

  test('rejects manifest permission changes without a new signature', () async {
    final changed = await manifest('bin/adapter')
      ..['permissions'] = ['workspace:read'];
    await expectLater(
      V7AdapterAdmission.admit(
        input: changed,
        packageRoot: root,
        expectedWorkerTypeId: 'codex',
        verifiedPackageDigest: digest,
        platform: 'linux-x64',
        trustPolicy: fixture.trustPolicy,
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
      throwsStateError,
    );
  });

  test(
      'rejects digest mismatch, untrusted publisher, unsupported platform and permissions',
      () async {
    final cases = [
      ((await manifest('bin/adapter'))..['packageDigest'] = 'b' * 64, 'digest'),
      ((await manifest('bin/adapter'))..['signature'] = 'forged', 'signature'),
      (await manifest('bin/adapter'), 'platform'),
      (await manifest('bin/adapter'), 'permission'),
    ];
    for (var i = 0; i < cases.length; i++) {
      final input = cases[i].$1;
      final reason = cases[i].$2;
      await expectLater(
        V7AdapterAdmission.admit(
          input: input,
          packageRoot: root,
          expectedWorkerTypeId: 'codex',
          verifiedPackageDigest: digest,
          platform: reason == 'platform' ? 'macos-arm64' : 'linux-x64',
          trustPolicy: fixture.trustPolicy,
          allowedPermissions: reason == 'permission'
              ? {WorkerPermission.readWorkspace}
              : WorkerPermission.values.toSet(),
        ),
        throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
      );
    }
  });

  test('rejects package traversal and does not launch without required secrets',
      () async {
    await expectLater(
      V7AdapterAdmission.admit(
        input: await manifest('../escape'),
        packageRoot: root,
        expectedWorkerTypeId: 'codex',
        verifiedPackageDigest: digest,
        platform: 'linux-x64',
        trustPolicy: fixture.trustPolicy,
        allowedPermissions: WorkerPermission.values.toSet(),
      ),
      throwsFormatException,
    );
    final admitted = await V7AdapterAdmission.admit(
      input: await manifest('bin/adapter'),
      packageRoot: root,
      expectedWorkerTypeId: 'codex',
      verifiedPackageDigest: digest,
      platform: 'linux-x64',
      trustPolicy: fixture.trustPolicy,
      allowedPermissions: WorkerPermission.values.toSet(),
    );
    expect(
      () => admitted.createProcessSpec(
        workerId: 'worker-1',
        workingDirectory: '/tmp/workstream',
        localConcurrencyLimit: 1,
        availableSecrets: const {},
      ),
      throwsStateError,
    );
  });
}
