import 'dart:io';
import 'package:conclave_worker_protocol/conclave_worker_protocol.dart';
import 'package:conclave_cli_worker_engine/src/model_discovery.dart';
import 'package:test/test.dart';

void main() {
  test(
    'TSV discovery preserves exact Gemini IDs and filters other providers',
    () {
      final models = parseDiscoveredModels(
        'gemini-new-high\tGemini New (High)\tlow,high\thigh\n'
            'claude-x\tClaude\n'
            'gemini-new-low\tGemini New (Low)\n',
        'gemini-',
      );
      expect(models.map((m) => m.id), ['gemini-new-high', 'gemini-new-low']);
      expect(models.first.name, 'Gemini New (High)');
      expect(models.first.supportedReasoningEfforts, ['low', 'high']);
      expect(models.first.defaultReasoningEffort, 'high');
      expect(models.every((m) => m.status == 'listed'), isTrue);
      expect(parseDiscoveredModels('claude-one\tOne', 'gemini-'), isEmpty);
      expect(
        parseDiscoveredModels('gpt-o3\tO3\tlow,high\thigh', ''),
        hasLength(1),
      );
    },
  );
  test('Codex app-server discovery maps models and per-model efforts', () {
    final models = parseCodexAppServerModels({
      'data': [
        {
          'id': 'gpt-6.1-sol',
          'displayName': 'GPT-6.1-Sol',
          'hidden': false,
          'defaultReasoningEffort': 'low',
          'supportedReasoningEfforts': [
            {'reasoningEffort': 'low', 'description': 'Fast'},
            {'reasoningEffort': 'high', 'description': 'Deep'},
          ],
        },
        {'id': 'gpt-hidden', 'displayName': 'Hidden', 'hidden': true},
        {'id': 'o3', 'displayName': 'o3', 'hidden': false},
      ],
      'nextCursor': null,
    }, 'gpt-');
    expect(models.map((model) => model.id), ['gpt-6.1-sol']);
    expect(models.single.supportedReasoningEfforts, ['low', 'high']);
    expect(models.single.defaultReasoningEffort, 'low');
  });

  test('Codex app-server discovery rejects invalid effort metadata', () {
    expect(
      () => parseCodexAppServerModels({
        'data': [
          {
            'id': 'gpt-one',
            'displayName': 'One',
            'supportedReasoningEfforts': [
              {'reasoningEffort': 'low'},
            ],
            'defaultReasoningEffort': 'high',
          },
        ],
      }, ''),
      throwsFormatException,
    );
  });

  test('Codex app-server discovery performs the JSON-RPC handshake', () async {
    final root = await Directory.systemTemp.createTemp('codex-app-server-');
    addTearDown(() => root.delete(recursive: true));
    final server = File('${root.path}/fake_app_server.dart');
    await server.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final request = jsonDecode(line) as Map;
    if (request['method'] == 'initialize') {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {'ok': true}}));
    } else if (request['method'] == 'model/list') {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {
        'data': [
          {'id': 'gpt-fixture', 'displayName': 'Fixture', 'supportedReasoningEfforts': [{'reasoningEffort': 'low'}], 'defaultReasoningEffort': 'low'}
        ],
        'nextCursor': null
      }}));
    }
  }
}
''');
    final models = await discoverCodexAppServerModels(
      executable: Platform.resolvedExecutable,
      arguments: ['run', server.path],
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
      workingDirectory: root.path,
      idPrefix: 'gpt-',
    );
    expect(models.single.id, 'gpt-fixture');
    expect(models.single.defaultReasoningEffort, 'low');
  });
  test('malformed, duplicate, empty and oversized results are rejected', () {
    for (final output in [
      'gemini-one',
      'gemini-one\tOne\ngemini-one\tTwo',
      'gemini-one\tOne\tlow\tmedium',
      'gemini-one\tOne\tlow\thigh\textra',
      'gemini-bad\tBad\u001b',
      List.generate(129, (i) => 'gemini-$i\tModel $i').join('\n'),
    ]) {
      expect(
        () => parseDiscoveredModels(output, 'gemini-'),
        throwsFormatException,
      );
    }
  });
  test(
    'cache survives restart, invalidates version/profile, and recovers corruption',
    () async {
      final root = await Directory.systemTemp.createTemp('model-discovery-');
      addTearDown(() => root.delete(recursive: true));
      final digest = 'a' * 64;
      final cache = ModelDiscoveryCache(root.path);
      await cache.save(
        DiscoveredModelCatalog(
          profileDigest: digest,
          providerToolVersion: '1.2.16',
          discoveredAt: '2026-10-11T00:00:00Z',
          models: [
            DiscoveredModel(id: 'gemini-one', name: 'One', status: 'verified'),
          ],
        ),
      );
      expect(
        (await ModelDiscoveryCache(
          root.path,
        ).load(digest, '1.2.16'))!.models.single.status,
        'verified',
      );
      expect(await cache.load(digest, '1.2.17'), isNull);
      expect(await cache.load('b' * 64, '1.2.16'), isNull);
      await cache.file.writeAsString('invalid');
      expect(await cache.load(digest, '1.2.16'), isNull);
    },
  );
}
