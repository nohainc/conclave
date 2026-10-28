import 'dart:convert';
import 'dart:io';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> copilot() => jsonDecode(
        File(
          '${Directory.current.path}/../../apps/profile_lab/assets/profiles/'
          'copilot.json',
        ).readAsStringSync(),
      ) as Map<String, Object?>;

  test('Copilot Profile reads quota over Content-Length JSON-RPC', () {
    final profile = copilot();
    EngineProfile.parse(utf8.encode(canonicalJson(profile)));
    expect(profile['usage'], {
      'arguments': ['--headless', '--stdio'],
      'timeoutMs': 20000,
      'jsonRpc': {'method': 'account.getQuota', 'framing': 'content_length'},
    });
  });

  test('rejects an unknown JSON-RPC framing', () {
    final profile = copilot();
    ((profile['usage']! as Map)['jsonRpc']! as Map)['framing'] = 'websocket';
    expect(
      () => EngineProfile.parse(utf8.encode(canonicalJson(profile))),
      throwsFormatException,
    );
  });
}
