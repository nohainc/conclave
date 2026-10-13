import 'dart:convert';
import 'dart:io';

/// Deterministic JSONL provider used by the Engine integration harness.
///
/// It intentionally behaves like a small Codex JSONL producer while exposing
/// controlled volume, delay, response-size and exit outcomes. It emits no
/// credentials or user content beyond the scenario name supplied by tests.
Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('activity-fixture 1.0.0');
    return;
  }

  final scenario = await stdin.transform(utf8.decoder).join();
  stdout.writeln(
    jsonEncode({
      'type': 'thread.started',
      'thread_id': 'fixture-thread-${scenario.hashCode.abs()}',
    }),
  );
  stdout.writeln(jsonEncode({'type': 'turn.started'}));

  if (scenario == 'delayed') {
    stdout.writeln(
      jsonEncode({
        'type': 'item.started',
        'item': {'id': 'delayed-tool', 'type': 'command_execution'},
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
  } else if (scenario == 'high-frequency') {
    for (var index = 0; index < 600; index++) {
      final id = 'tool-$index';
      stdout.writeln(
        jsonEncode({
          'type': 'item.started',
          'item': {'id': id, 'type': 'command_execution'},
        }),
      );
      stdout.writeln(
        jsonEncode({
          'type': 'item.completed',
          'item': {'id': id, 'type': 'command_execution'},
        }),
      );
    }
  } else {
    stdout.writeln(
      jsonEncode({
        'type': 'item.started',
        'item': {'id': 'tool-1', 'type': 'command_execution'},
      }),
    );
    stdout.writeln(
      jsonEncode({
        'type': 'item.completed',
        'item': {'id': 'tool-1', 'type': 'command_execution'},
      }),
    );
  }

  final response = scenario == 'large'
      ? 'x' * (128 * 1024)
      : 'fixture response: $scenario';
  stdout.writeln(
    jsonEncode({
      'type': 'item.completed',
      'item': {'type': 'agent_message', 'text': response},
    }),
  );
  if (scenario != 'no-terminal') {
    stdout.writeln(jsonEncode({'type': 'turn.completed'}));
  }
  await stdout.flush();

  if (scenario == 'fail') exitCode = 7;
}
