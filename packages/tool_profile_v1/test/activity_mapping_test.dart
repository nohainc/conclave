import 'dart:convert';

import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';
import 'package:test/test.dart';

import 'tool_profile_release_test.dart';

void main() {
  Map<String, Object?> profileWithActivity() {
    final profile = validProfileMap();
    (profile['execution'] as Map<String, Object?>)['output'] = {
      'mode': 'jsonl',
    };
    profile['activity'] = {
      'mappings': [
        {
          'when': [
            {'kind': 'equals', 'selector': r'$.type', 'value': 'tool.started'},
          ],
          'type': 'tool.started',
          'status': 'running',
          'title': 'Running tool',
          'activityIdSelector': r'$.id',
          'detailSelectors': {'toolName': r'$.tool'},
        },
        {
          'when': [
            {'kind': 'equals', 'selector': r'$.type', 'value': 'tool.done'},
          ],
          'type': 'tool.completed',
          'status': 'completed',
          'title': 'Tool completed',
          'activityIdSelector': r'$.id',
          'detailSelectors': {'toolName': r'$.tool'},
        },
      ],
    };
    return profile;
  }

  test('replays repeated tool mappings with normalized results', () {
    final profile = profileWithActivity();
    final results = mapProfileActivityEvents(profile, [
      {'type': 'unknown'},
      {'type': 'tool.started', 'id': 'one', 'tool': 'shell'},
      {'type': 'tool.done', 'id': 'one', 'tool': 'shell'},
      {'type': 'tool.started', 'id': 'two', 'tool': 'shell'},
      {'type': 'tool.done', 'id': 'two', 'tool': 'shell'},
    ]);
    expect(results.map((result) => result.type), [
      'tool.started',
      'tool.completed',
      'tool.started',
      'tool.completed',
    ]);
    expect(results.map((result) => result.activityId),
        ['one', 'one', 'two', 'two']);
    expect(results.every((result) => result.percentage == null), isTrue);
  });

  test('rejects unsupported activity fields and unsafe selectors', () {
    final unknownField = profileWithActivity();
    ((unknownField['activity'] as Map)['mappings'] as List).first['transform'] =
        'script';
    expect(
      () => EngineProfile.parse(utf8.encode(canonicalJson(unknownField))),
      throwsFormatException,
    );

    final unsafeSelector = profileWithActivity();
    ((unsafeSelector['activity'] as Map)['mappings'] as List)
        .first['detailSelectors'] = {'raw': r'$.stdout'};
    expect(
      () => EngineProfile.parse(utf8.encode(canonicalJson(unsafeSelector))),
      throwsFormatException,
    );
  });
}
