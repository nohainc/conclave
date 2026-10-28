import 'dart:convert';
import 'dart:io';

import 'package:syntila_tool_profile_v1/tool_profile_v1.dart';
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

  test('ChatGPT Codex authoring Profile maps live Codex events', () {
    final file = File(
      '${Directory.current.path}/../../apps/profile_lab/assets/profiles/'
      'chatgpt.json',
    );
    final profile = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    // The authoring document must still parse as a valid Tool Profile.
    EngineProfile.parse(utf8.encode(canonicalJson(profile)));

    List<String> types(Map<String, Object?> event) => mapProfileActivityEvents(
          profile,
          [event],
        ).map((result) => '${result.type}:${result.title}').toList();

    expect(types({'type': 'turn.started'}), ['model.started:Thinking']);
    expect(
      types({
        'type': 'item.started',
        'item': {'id': 'a', 'type': 'command_execution'},
      }),
      ['tool.started:Running a command'],
    );
    expect(
      types({
        'type': 'item.started',
        'item': {'id': 'b', 'type': 'web_search'},
      }),
      ['tool.started:Searching the web'],
    );
    expect(
      types({
        'type': 'item.completed',
        'item': {'id': 'c', 'type': 'file_change', 'status': 'completed'},
      }),
      ['tool.completed:File edits applied'],
    );
    // A failed command is reported as completed and then failed, with the same
    // activity id, so the client merges it into one failed row.
    final failed = mapProfileActivityEvents(profile, [
      {
        'type': 'item.completed',
        'item': {'id': 'd', 'type': 'command_execution', 'status': 'failed'},
      },
    ]);
    expect(
        failed.map((result) => result.type), ['tool.completed', 'tool.failed']);
    expect(failed.map((result) => result.activityId), ['d', 'd']);
    expect(
      types({
        'type': 'item.updated',
        'item': {'id': 'e', 'type': 'todo_list'},
      }),
      ['model.status:Updating the plan'],
    );
    expect(
      types({
        'type': 'item.completed',
        'item': {'id': 'f', 'type': 'agent_message', 'text': 'hello'},
      }),
      ['message.updated:Writing the response'],
    );
    expect(types({'type': 'unknown.provider.event'}), isEmpty);
  });

  test('Antigravity live-activity starter maps documented agy step updates',
      () {
    final file = File(
      '${Directory.current.path}/../../apps/profile_lab/assets/profiles/'
      'gemini.json',
    );
    final profile = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    EngineProfile.parse(utf8.encode(canonicalJson(profile)));

    List<String> types(Map<String, Object?> event) => mapProfileActivityEvents(
          profile,
          [event],
        ).map((result) => '${result.type}:${result.title}').toList();

    Map<String, Object?> step(
            int index, String state, Map<String, Object?> extra) =>
        {
          'event': 'step_update',
          'step_update': {
            'conversation_id': 'c1',
            'step_index': index,
            'state': state,
            'step_type': 'tool',
            'tool_name': 'run_command',
            ...extra,
          },
        };

    expect(types({'event': 'init'}), ['model.started:Thinking']);
    expect(types(step(2, 'ACTIVE', {})), ['tool.started:Running a tool']);
    expect(
      types(step(2, 'DONE', {
        'tool_info': {'name': 'run_command', 'output': 'x'}
      })),
      ['tool.completed:Tool completed'],
    );
    expect(
      types(step(2, 'DONE', {
        'tool_info': {
          'name': 'run_command',
          'error': {'message': 'denied'}
        },
      })),
      ['tool.failed:Tool failed'],
    );

    // Started and completed events for one step pair by step_index.
    final started =
        mapProfileActivityEvents(profile, [step(2, 'ACTIVE', {})]).single;
    final completed = mapProfileActivityEvents(
      profile,
      [
        step(2, 'DONE', {
          'tool_info': {'name': 'run_command'}
        })
      ],
    ).single;
    expect(started.activityId, '2');
    expect(completed.activityId, '2');
  });
}
