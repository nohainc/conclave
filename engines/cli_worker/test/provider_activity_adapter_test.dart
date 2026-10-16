import 'dart:convert';
import 'dart:io';

import 'package:conclave_cli_worker_engine/conclave_cli_worker_engine.dart';
import 'package:test/test.dart';

void main() {
  final root = Directory.current.parent.parent;

  List<String> fixture(String provider) => File(
    '${root.path}/packages/tool-profile/test/fixtures/$provider-events/adapter-edge-cases.jsonl',
  ).readAsLinesSync();

  test(
    'Codex adapter preserves missing-id tool pairs and reports failures',
    () {
      final adapter = ProviderActivityAdapter.fromProfile({
        'providerTool': {'name': 'codex'},
        'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
      })!;
      final observations = <ProviderActivityObservation>[];
      for (final line in fixture('codex')) {
        observations.addAll(
          adapter.normalizeLine(
            line,
            declarativeMatched: line.contains('item.'),
          ),
        );
      }

      final tools = observations
          .where(
            (event) =>
                event.type == 'tool.started' ||
                event.type == 'tool.completed' ||
                event.type == 'tool.failed',
          )
          .toList();
      expect(tools.map((event) => event.type), [
        'tool.started',
        'tool.completed',
        'tool.failed',
      ]);
      expect(tools[0].activityId, tools[1].activityId);
      expect(tools[0].activityId, isNotEmpty);
      expect(tools[0].details['identifierSource'], 'generated');
      expect(
        observations.map((event) => event.details['diagnostic']),
        containsAll(['provider_error', 'malformed_json']),
      );
    },
  );

  test('agy adapter preserves missing-id tool pairs and failed tools', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'agy'},
      'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
    })!;
    final observations = <ProviderActivityObservation>[];
    for (final line in fixture('antigravity')) {
      observations.addAll(
        adapter.normalizeLine(
          line,
          declarativeMatched: line.contains('ACTIVE'),
        ),
      );
    }

    final tools = observations
        .where(
          (event) =>
              event.type == 'tool.started' ||
              event.type == 'tool.completed' ||
              event.type == 'tool.failed',
        )
        .toList();
    expect(tools.map((event) => event.type), [
      'tool.started',
      'tool.completed',
      'tool.failed',
    ]);
    expect(tools[0].activityId, tools[1].activityId);
    expect(tools[0].details['identifierSource'], 'generated');
    expect(
      observations.map((event) => event.details['diagnostic']),
      containsAll(['provider_error', 'malformed_json']),
    );
  });

  test('adapter IDs remain distinct for repeated missing-id invocations', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'codex'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    final starts = <String?>[];
    for (var index = 0; index < 2; index++) {
      final event =
          jsonDecode(
                '{"type":"item.started","item":{"type":"command_execution"}}',
              )
              as Map<String, Object?>;
      starts.add(
        adapter
            .normalizeEvent(event, declarativeMatched: true)
            .single
            .activityId,
      );
    }
    expect(starts[0], isNot(starts[1]));
  });

  test('Codex adapter extracts content-array final responses', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Codex CLI'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    expect(
      adapter.finalResponseText({
        'type': 'item.completed',
        'item': {
          'type': 'agent_message',
          'content': [
            {'type': 'output_text', 'text': 'first'},
            {'type': 'output_text', 'text': ' second'},
          ],
        },
      }),
      'first second',
    );
  });

  test('Codex adapter treats non-tool item updates as expected progress', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Codex CLI'},
      'activity': {'adapter': 'codex-jsonl', 'mappings': <Object?>[]},
    })!;
    for (final itemType in ['todo_list', 'reasoning', 'agent_message']) {
      expect(
        adapter.normalizeEvent({
          'type': 'item.updated',
          'item': {'id': 'item-1', 'type': itemType},
        }, declarativeMatched: true),
        isEmpty,
        reason: '$itemType updates must not raise a diagnostic',
      );
    }
    final searchUpdate = adapter.normalizeEvent({
      'type': 'item.updated',
      'item': {'id': 'search-1', 'type': 'web_search'},
    }, declarativeMatched: true);
    expect(searchUpdate.single.type, 'model.status');
    expect(searchUpdate.single.activityId, 'search-1');
  });

  test('agy adapter pairs documented tool steps by step index', () {
    final adapter = ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'agy'},
      'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
    })!;
    Map<String, Object?> step(Map<String, Object?> fields) => {
      'event': 'step_update',
      'step_update': {'conversation_id': 'c1', ...fields},
    };

    final started = adapter.normalizeEvent(
      step({
        'step_index': 2,
        'state': 'ACTIVE',
        'step_type': 'tool',
        'tool_name': 'run_command',
      }),
      declarativeMatched: false,
    );
    final completed = adapter.normalizeEvent(
      step({
        'step_index': 2,
        'state': 'DONE',
        'step_type': 'tool',
        'tool_name': 'run_command',
        'tool_info': {'name': 'run_command', 'output': 'ok'},
      }),
      declarativeMatched: false,
    );
    final failed = adapter.normalizeEvent(
      step({
        'step_index': 3,
        'state': 'DONE',
        'step_type': 'tool',
        'tool_name': 'run_command',
        'tool_info': {
          'name': 'run_command',
          'error': {'type': 'permission', 'message': 'denied'},
        },
      }),
      declarativeMatched: false,
    );

    expect(started.single.type, 'tool.started');
    expect(completed.single.type, 'tool.completed');
    expect(completed.single.activityId, started.single.activityId);
    expect(failed.single.type, 'tool.failed');
    expect(failed.single.activityId, isNot(started.single.activityId));
    // Checkpoints and responses are expected steps, not diagnostics.
    expect(
      adapter.normalizeEvent(
        step({'step_index': 4, 'state': 'ACTIVE', 'step_type': 'checkpoint'}),
        declarativeMatched: false,
      ),
      isEmpty,
    );
  });

  group('Claude adapter', () {
    ProviderActivityAdapter adapter() => ProviderActivityAdapter.fromProfile({
      'providerTool': {'name': 'Claude Code'},
      'activity': {'adapter': 'claude-stream-json', 'mappings': <Object?>[]},
    })!;

    List<ProviderActivityObservation> line(
      ProviderActivityAdapter adapter,
      Map<String, Object?> event,
    ) => adapter.normalizeLine(jsonEncode(event), declarativeMatched: false);

    test('is selected from the declared adapter or the provider name', () {
      expect(
        ProviderActivityAdapter.fromProfile({
          'providerTool': {'name': 'Claude Code'},
          'activity': {'mappings': <Object?>[]},
        })?.kind,
        'claude-stream-json',
      );
      expect(adapter().kind, 'claude-stream-json');
    });

    test('pairs tool_use with tool_result and reports failures', () {
      final claude = adapter();
      final started = line(claude, {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'thinking', 'thinking': 'secret reasoning'},
            {'type': 'text', 'text': 'secret answer'},
            {
              'type': 'tool_use',
              'id': 'toolu_01',
              'name': 'Bash',
              'input': {'command': 'secret command'},
            },
          ],
        },
      });
      expect(started.map((e) => e.type), [
        'model.status',
        'message.updated',
        'tool.started',
      ]);
      expect(started.last.activityId, 'toolu_01');
      expect(started.last.title, 'Running a command');
      expect(started.last.details['toolKind'], 'Bash');

      final done = line(claude, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_01',
              'content': 'secret output',
            },
          ],
        },
      });
      expect(done.single.type, 'tool.completed');
      expect(done.single.activityId, 'toolu_01');

      final failed = line(claude, {
        'type': 'user',
        'message': {
          'content': [
            {
              'type': 'tool_result',
              'tool_use_id': 'toolu_02',
              'is_error': true,
              'content': 'secret error',
            },
          ],
        },
      });
      expect(failed.single.type, 'tool.failed');
      expect(failed.single.status, 'failed');
      expect(failed.single.activityId, 'toolu_02');

      // Nothing from prompts, reasoning, input or output crosses the boundary.
      final everything = [
        ...started,
        ...done,
        ...failed,
      ].map((e) => '${e.title} ${e.details} ${e.activityId}').join(' ');
      expect(everything, isNot(contains('secret')));
    });

    test('titles tools by name and ignores unrelated events silently', () {
      final claude = adapter();
      String title(String name) => line(claude, {
        'type': 'assistant',
        'message': {
          'content': [
            {'type': 'tool_use', 'id': 'toolu_$name', 'name': name},
          ],
        },
      }).single.title;
      expect(title('Edit'), 'Editing files');
      expect(title('Read'), 'Reading files');
      expect(title('WebSearch'), 'Searching the web');
      expect(title('Task'), 'Working with a sub-agent');
      expect(title('mcp__server__tool'), 'Using a connected tool');
      expect(title('SomethingNew'), 'Running a tool');

      final init = line(claude, {'type': 'system', 'subtype': 'init'});
      expect(init.single.type, 'model.started');
      expect(init.single.title, 'Thinking');
      expect(line(claude, {'type': 'system', 'subtype': 'api_retry'}), isEmpty);
      for (final type in ['result', 'stream_event', 'rate_limit_event']) {
        expect(line(claude, {'type': type, 'subtype': 'init'}), isEmpty);
      }
      expect(
        line(claude, {
          'type': 'assistant',
          'message': {'content': 'plain'},
        }),
        isEmpty,
      );
    });
  });

  test(
    'agy adapter defers to a matched mapping that keys tools by step_index',
    () {
      final adapter = ProviderActivityAdapter.fromProfile({
        'providerTool': {'name': 'agy'},
        'activity': {'adapter': 'agy-stream-json', 'mappings': <Object?>[]},
      })!;
      Map<String, Object?> tool(String state) => {
        'event': 'step_update',
        'step_update': {
          'conversation_id': 'c1',
          'step_index': 1,
          'state': state,
          'step_type': 'tool',
          'tool_name': 'run_command',
        },
      };
      // The Profile mapping already reported these under id "1".
      expect(
        adapter.normalizeEvent(tool('ACTIVE'), declarativeMatched: true),
        isEmpty,
      );
      expect(
        adapter.normalizeEvent(tool('DONE'), declarativeMatched: true),
        isEmpty,
      );
      // Without a matching mapping the adapter still provides the pair.
      expect(
        adapter.normalizeEvent(tool('ACTIVE'), declarativeMatched: false),
        hasLength(1),
      );
    },
  );
}
