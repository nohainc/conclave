import 'package:conclave_tool_profile_v1/tool_profile_v1.dart';

/// Sanitized, provider-native events used by Profile Lab's deterministic
/// mapping check. They contain identifiers and event metadata only; no prompt,
/// model response, command, terminal output or environment values.
class ProfileActivityMappingReplayResult {
  const ProfileActivityMappingReplayResult({
    required this.status,
    required this.provider,
    required this.fixtureName,
    required this.events,
    required this.activities,
    required this.message,
  });

  final String status; // passed, failed, not_applicable
  final String provider;
  final String? fixtureName;
  final List<Map<String, Object?>> events;
  final List<ProfileActivityMappingResult> activities;
  final String message;

  bool get passed => status == 'passed';
}

ProfileActivityMappingReplayResult replayProfileActivityMappings(
  Map<String, Object?> profile,
) {
  final providerTool = profile['providerTool'];
  final provider = providerTool is Map
      ? (providerTool['name'] as String? ?? 'unknown')
      : 'unknown';
  final activity = profile['activity'];
  final mappings = activity is Map ? activity['mappings'] : null;
  final output = profile['execution'];
  final outputMode = output is Map && output['output'] is Map
      ? (output['output'] as Map)['mode']
      : null;
  if (mappings is! List || mappings.isEmpty || outputMode != 'jsonl') {
    return ProfileActivityMappingReplayResult(
      status: 'not_applicable',
      provider: provider,
      fixtureName: null,
      events: const [],
      activities: const [],
      message: mappings is! List || mappings.isEmpty
          ? 'No structured activity mappings are declared.'
          : 'The Profile uses a non-JSONL output contract; provider event replay is not applicable.',
    );
  }

  final fixture = _fixtureFor(provider);
  if (fixture == null) {
    return ProfileActivityMappingReplayResult(
      status: 'failed',
      provider: provider,
      fixtureName: null,
      events: const [],
      activities: const [],
      message: 'No sanitized event fixture is registered for this provider.',
    );
  }
  final activities = mapProfileActivityEvents(profile, fixture.events);
  final toolIds = activities
      .where((activity) => activity.type == 'tool.started')
      .map((activity) => activity.activityId)
      .whereType<String>()
      .toSet();
  final hasLifecyclePair = toolIds.isNotEmpty &&
      toolIds.every(
        (id) => activities.any(
          (activity) =>
              activity.type == 'tool.completed' && activity.activityId == id,
        ),
      );
  final passed = activities.isNotEmpty && hasLifecyclePair;
  return ProfileActivityMappingReplayResult(
    status: passed ? 'passed' : 'failed',
    provider: provider,
    fixtureName: fixture.name,
    events: fixture.events,
    activities: activities,
    message: passed
        ? 'Mapped ${activities.length} normalized activities, including ${toolIds.length} repeated tool calls.'
        : 'The fixture did not produce complete tool lifecycle mappings.',
  );
}

class _ProfileActivityFixture {
  const _ProfileActivityFixture(this.name, this.events);

  final String name;
  final List<Map<String, Object?>> events;
}

_ProfileActivityFixture? _fixtureFor(String provider) {
  final normalized = provider.toLowerCase();
  if (normalized.contains('codex')) {
    return const _ProfileActivityFixture('codex-events/success.jsonl', [
      {'type': 'thread.started', 'thread_id': 'fixture-session-1'},
      {'type': 'unknown.provider.event', 'ignored': true},
      {'type': 'turn.started'},
      {
        'type': 'item.started',
        'item': {'id': 'tool-call-1', 'type': 'command_execution'},
      },
      {
        'type': 'item.completed',
        'item': {'id': 'tool-call-1', 'type': 'command_execution'},
      },
      {
        'type': 'item.started',
        'item': {'id': 'tool-call-2', 'type': 'command_execution'},
      },
      {
        'type': 'item.completed',
        'item': {'id': 'tool-call-2', 'type': 'command_execution'},
      },
      {
        'type': 'item.completed',
        'item': {'type': 'agent_message', 'text': '[redacted fixture text]'},
      },
      {'type': 'turn.completed'},
    ]);
  }
  if (normalized.contains('agy') || normalized.contains('antigravity')) {
    return const _ProfileActivityFixture(
      'antigravity-events/success.jsonl',
      [
        {
          'event': 'init',
          'conversation_id': 'fixture-conversation-1',
        },
        {
          'event': 'step_update',
          'step_update': {
            'state': 'ACTIVE',
            'step_type': 'agent_response',
          },
        },
        {
          'event': 'step_update',
          'step_update': {
            'state': 'ACTIVE',
            'step_type': 'tool_execution',
            'tool_id': 'tool-call-1',
            'tool_name': 'shell',
          },
        },
        {
          'event': 'step_update',
          'step_update': {
            'state': 'COMPLETED',
            'step_type': 'tool_execution',
            'tool_id': 'tool-call-1',
            'tool_name': 'shell',
          },
        },
        {
          'event': 'step_update',
          'step_update': {
            'state': 'ACTIVE',
            'step_type': 'tool_execution',
            'tool_id': 'tool-call-2',
            'tool_name': 'shell',
          },
        },
        {
          'event': 'step_update',
          'step_update': {
            'state': 'COMPLETED',
            'step_type': 'tool_execution',
            'tool_id': 'tool-call-2',
            'tool_name': 'shell',
          },
        },
        {
          'event': 'result',
          'result': {'conversation_id': 'fixture-conversation-1'},
        },
      ],
    );
  }
  return null;
}
