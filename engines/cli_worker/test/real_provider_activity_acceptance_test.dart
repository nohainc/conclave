import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:syntila_cli_worker_engine/syntila_cli_worker_engine.dart';
import 'package:test/test.dart';

Future<void> _assertProvider({
  required Directory repository,
  required String profileName,
  required String executable,
  required List<String> arguments,
  required String input,
}) async {
  final profile =
      jsonDecode(
            await File(
              '${repository.path}/packages/tool-profile/test/fixtures/$profileName',
            ).readAsString(),
          )
          as Map<String, Object?>;
  final adapter = ProviderActivityAdapter.fromProfile(profile);
  expect(adapter, isNotNull);

  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: repository.path,
    runInShell: false,
  );
  final stderr = StringBuffer();
  final stderrSubscription = process.stderr
      .transform(utf8.decoder)
      .listen(stderr.write);
  process.stdin.writeln(input);
  await process.stdin.close();
  final output = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .toList()
      .timeout(const Duration(minutes: 2));
  final exitCode = await process.exitCode;
  await stderrSubscription.cancel();
  expect(exitCode, 0, reason: stderr.toString());

  final normalizedTypes = <String>[];
  for (final line in output) {
    Object? event;
    try {
      event = jsonDecode(line);
    } on Object {
      event = null;
    }
    final mapped = event is Map
        ? mapProfileActivityEvents(profile, [event])
        : const <ProfileActivityMappingResult>[];
    normalizedTypes.addAll(mapped.map((item) => item.type));
    if (event is Map) {
      normalizedTypes.addAll(
        adapter!
            .normalizeEvent(event, declarativeMatched: mapped.isNotEmpty)
            .map((item) => item.type),
      );
    } else {
      normalizedTypes.addAll(
        adapter!
            .normalizeLine(line, declarativeMatched: false)
            .map((item) => item.type),
      );
    }
  }
  expect(normalizedTypes, isNotEmpty);
  expect(
    normalizedTypes.any(
      const {'model.started', 'model.status', 'tool.started'}.contains,
    ),
    isTrue,
  );
}

void main() {
  final enabled =
      Platform.environment['SYNTILA_REAL_PROVIDER_ACCEPTANCE'] == '1';
  final repository = Directory.current.parent.parent;

  test(
    'real Codex CLI emits normalizable activity',
    () => _assertProvider(
      repository: repository,
      profileName: 'chatgpt-codex.v1.json',
      executable: Platform.environment['SYNTILA_CODEX_EXECUTABLE'] ?? 'codex',
      arguments: [
        'exec',
        '--json',
        '--color',
        'never',
        '--skip-git-repo-check',
        '--cd',
        repository.path,
        '--ephemeral',
        '-',
      ],
      input:
          'Use one available tool to inspect the current directory, then summarize the result briefly.',
    ),
    skip: enabled ? false : 'set SYNTILA_REAL_PROVIDER_ACCEPTANCE=1 to run',
  );

  test(
    'real agy CLI emits normalizable activity',
    () => _assertProvider(
      repository: repository,
      profileName: 'gemini-antigravity.v1.json',
      executable: Platform.environment['SYNTILA_AGY_EXECUTABLE'] ?? 'agy',
      arguments: [
        '--input-format',
        'stream-json',
        '--output-format',
        'stream-json',
        '--mode',
        'plan',
      ],
      input: jsonEncode({
        'event': 'user',
        'message': {
          'content':
              'Use one available tool to inspect the current directory, then summarize the result briefly.',
        },
      }),
    ),
    skip: enabled ? false : 'set SYNTILA_REAL_PROVIDER_ACCEPTANCE=1 to run',
  );
}
