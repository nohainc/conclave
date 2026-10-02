import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_engine/conclave_cli_worker_engine.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent;
  final fixture = File(
    '${root.path}/packages/tool-profile/test/fixtures/fixture-cli.v1.json',
  );

  Map<String, Object?> readProfile() =>
      jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;

  List<int> encode(Map<String, Object?> profile) =>
      utf8.encode(jsonEncode(profile));

  test(
    'accepts current official provider profiles and declared provider keys',
    () {
      for (final name in [
        'chatgpt-codex.v1.json',
        'gemini-antigravity.v1.json',
      ]) {
        final bytes = File(
          '${root.path}/packages/tool-profile/test/fixtures/$name',
        ).readAsBytesSync();
        expect(() => EngineProfile.parse(bytes), returnsNormally, reason: name);
      }
      final profile = readProfile();
      (profile['environment'] as Map<String, Object?>)['passthrough'] = [
        'OPENAI_API_KEY',
      ];
      expect(() => EngineProfile.parse(encode(profile)), returnsNormally);
    },
  );

  test('rejects host and cloud secret environment requests', () {
    for (final name in [
      'CONCLAVE_CLOUD_SECRET',
      'CLOUD_API_KEY',
      'WORKSPACE_TOKEN',
    ]) {
      final profile = readProfile();
      (profile['environment'] as Map<String, Object?>)['passthrough'] = [name];
      expect(
        () => EngineProfile.parse(encode(profile)),
        throwsFormatException,
        reason: name,
      );
    }
  });

  test('rejects oversized Profile environment values', () {
    final profile = readProfile();
    (profile['environment'] as Map<String, Object?>)['set'] = {
      'TOOL_OPTION': 'x' * 4097,
    };
    expect(() => EngineProfile.parse(encode(profile)), throwsFormatException);
  });

  test('rejects executable paths and discovery traversal', () {
    final executable = readProfile();
    (executable['providerTool']
        as Map<String, Object?>)['executableCandidates'] = [
      '/bin/sh',
    ];
    expect(
      () => EngineProfile.parse(encode(executable)),
      throwsFormatException,
    );

    final traversal = readProfile();
    ((traversal['providerTool'] as Map<String, Object?>)['discovery']
        as Map<String, Object?>)['standardLocations'] = [
      '{{home}}/../../tmp',
    ];
    expect(() => EngineProfile.parse(encode(traversal)), throwsFormatException);

    final configTraversal = readProfile();
    final passive =
        ((configTraversal['probe'] as Map<String, Object?>)['passive']
            as Map<String, Object?>);
    passive['configChecks'] = [
      {'root': 'home', 'relativePath': '../outside', 'rules': <Object?>[]},
    ];
    expect(
      () => EngineProfile.parse(encode(configTraversal)),
      throwsFormatException,
    );
  });

  test(
    'rejects selector depth bombs, oversized rules, and unknown sandbox policy',
    () {
      final selector = readProfile();
      (selector['progress'] as List<Object?>).add({
        'when': [
          {
            'kind': 'exists',
            'selector': r'$.a.b.c.d.e.f.g.h.i.j.k.l.m.n.o.p.q',
          },
        ],
        'percentage': 1,
        'messageKey': 'invalid',
      });
      expect(
        () => EngineProfile.parse(encode(selector)),
        throwsFormatException,
      );

      final rules = readProfile();
      (rules['execution'] as Map<String, Object?>)['events'] = List.generate(
        129,
        (_) => {'when': <Object?>[], 'actions': <Object?>[]},
      );
      expect(() => EngineProfile.parse(encode(rules)), throwsFormatException);

      final sandbox = readProfile();
      ((sandbox['sandbox'] as Map<String, Object?>)['mappings']
              as Map<String, Object?>)['arbitrary'] =
          <String>[];
      expect(() => EngineProfile.parse(encode(sandbox)), throwsFormatException);
    },
  );

  test('confines session state files to the Engine state directory', () async {
    final root = await Directory.systemTemp.createTemp(
      'conclave-session-state-',
    );
    final outside = File(
      '${root.parent.path}/conclave-session-outside-${root.hashCode}',
    );
    final store = EngineSessionStore(root);
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
      await root.delete(recursive: true);
    });

    Future<void> write(String sessionKey) => store.write(
      sessionKey: sessionKey,
      workerTypeId: 'fixture-worker',
      profileDefinitionId: 'fixture-cli',
      providerToolIdentity: 'Fixture CLI',
      profileReleaseVersion: 1,
      sessionFormatId: 'fixture-session-v1',
      sessionId: 'safe_session_1',
    );

    await expectLater(write('../outside'), throwsFormatException);
    await outside.writeAsString('{"sessionId":"outside"}');
    await write('linked');
    final linkedState = root.listSync().whereType<File>().single;
    await linkedState.delete();
    Link(linkedState.path).createSync(outside.path);
    await expectLater(write('linked'), throwsFormatException);
  });

  test(
    'session mappings are scoped and Profile format compatibility is explicit',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'conclave-session-scope-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final store = EngineSessionStore(directory);
      const workerTypeId = 'fixture-worker';
      const profileDefinitionId = 'fixture-cli';
      const providerToolIdentity = 'Fixture CLI';

      Future<String?> read({
        String worker = workerTypeId,
        String profile = profileDefinitionId,
        String provider = providerToolIdentity,
        List<String> formats = const ['fixture-session-v1'],
      }) => store.read(
        sessionKey: 'logical-session',
        workerTypeId: worker,
        profileDefinitionId: profile,
        providerToolIdentity: provider,
        compatibleFormatIds: formats,
      );

      await File('${directory.path}/logical-session.json').writeAsString(
        jsonEncode({'sessionId': 'legacy-unpartitioned-session'}),
      );
      expect(
        await read(),
        isNull,
        reason:
            'Legacy unpartitioned state must start a fresh provider session',
      );
      await store.write(
        sessionKey: 'logical-session',
        workerTypeId: workerTypeId,
        profileDefinitionId: profileDefinitionId,
        providerToolIdentity: providerToolIdentity,
        profileReleaseVersion: 1,
        sessionFormatId: 'fixture-session-v1',
        sessionId: 'provider-session-1',
      );

      expect(await read(), 'provider-session-1');
      expect(
        await read(formats: const ['fixture-session-v2']),
        isNull,
        reason: 'An incompatible Profile release starts a new provider session',
      );
      expect(await read(worker: 'another-worker'), isNull);
      expect(await read(profile: 'another-profile'), isNull);
      expect(await read(provider: 'Another CLI'), isNull);
    },
  );
}
