import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A provider observation that has already been reduced to safe, bounded
/// Worker Activity fields. Provider payloads and tool output never cross this
/// boundary.
class ProviderActivityObservation {
  const ProviderActivityObservation({
    required this.type,
    required this.status,
    required this.title,
    this.activityId,
    this.details = const <String, Object?>{},
  });

  final String type;
  final String status;
  final String title;
  final String? activityId;
  final Map<String, Object?> details;
}

/// Handles provider event families that cannot be expressed safely by the
/// declarative Profile mapping grammar. This is deliberately kept at the
/// generic Engine boundary; Cloud and Core do not know provider event shapes.
class ProviderActivityAdapter {
  ProviderActivityAdapter._(this.kind);

  final String kind;
  final Set<String> _reportedDiagnostics = <String>{};
  final Map<String, int> _fallbackCounts = <String, int>{};
  final Map<String, List<String>> _pendingFallbackIds =
      <String, List<String>>{};

  static ProviderActivityAdapter? fromProfile(Map<String, Object?> profile) {
    final activity = profile['activity'];
    if (activity is! Map) return null;
    final declared = activity['adapter'];
    if (declared is String &&
        const {'codex-jsonl', 'agy-stream-json'}.contains(declared)) {
      return ProviderActivityAdapter._(declared);
    }
    final provider = profile['providerTool'];
    final name = provider is Map ? provider['name'] : null;
    final normalizedName = name is String ? name.toLowerCase() : '';
    if (normalizedName.contains('codex')) {
      return ProviderActivityAdapter._('codex-jsonl');
    }
    if (normalizedName == 'agy' || normalizedName.contains('antigravity')) {
      return ProviderActivityAdapter._('agy-stream-json');
    }
    return null;
  }

  /// Normalizes one provider line. [declarativeMatched] tells the adapter
  /// that the ordinary Profile mapping already produced the event, so the
  /// adapter only adds a fallback for missing identifiers or unsupported
  /// lifecycle/error variants.
  List<ProviderActivityObservation> normalizeLine(
    String line, {
    required bool declarativeMatched,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on Object {
      return _diagnostic('malformed_json');
    }
    if (decoded is! Map) return _diagnostic('unsupported_event_shape');
    return normalizeEvent(decoded, declarativeMatched: declarativeMatched);
  }

  List<ProviderActivityObservation> normalizeEvent(
    Map event, {
    required bool declarativeMatched,
  }) {
    return switch (kind) {
      'codex-jsonl' => _normalizeCodex(
        event,
        declarativeMatched: declarativeMatched,
      ),
      'agy-stream-json' => _normalizeAgy(
        event,
        declarativeMatched: declarativeMatched,
      ),
      _ => _diagnostic('unsupported_adapter'),
    };
  }

  /// Returns a provider final response when the provider encodes message text
  /// outside the Profile's simple scalar selector. Codex has emitted both
  /// `item.text` and `item.content[].text` forms across CLI releases.
  ///
  /// This is deliberately a response-only extraction. It does not expose the
  /// provider event or tool output to activity consumers.
  String? finalResponseText(Map event) {
    if (kind != 'codex-jsonl') return null;
    final type = event['type'];
    if (type == 'turn.completed' && event['final_response'] is String) {
      final response = (event['final_response'] as String).trimRight();
      return response.isEmpty ? null : response;
    }
    if (type != 'item.completed' && type != 'item.updated') return null;
    final item = event['item'];
    if (item is! Map || item['type'] != 'agent_message') return null;
    final scalar = item['text'];
    if (scalar is String && scalar.trim().isNotEmpty) return scalar;
    final content = item['content'];
    if (content is! List) return null;
    final parts = <String>[];
    for (final entry in content) {
      if (entry is String && entry.trim().isNotEmpty) {
        parts.add(entry);
      } else if (entry is Map && entry['text'] is String) {
        final text = entry['text'] as String;
        if (text.trim().isNotEmpty) parts.add(text);
      }
    }
    if (parts.isEmpty) return null;
    return parts.join();
  }

  List<ProviderActivityObservation> _normalizeCodex(
    Map event, {
    required bool declarativeMatched,
  }) {
    final type = event['type'];
    if (type is! String) return _diagnostic('missing_event_type');
    final item = event['item'];
    final itemMap = item is Map ? item : const <Object?, Object?>{};
    final itemType = itemMap['type'];
    final isTool = const {
      'command_execution',
      'mcp_tool_call',
      'web_search_call',
      'web_search',
      'collab_tool_call',
      'file_change',
    }.contains(itemType);
    final toolKind = itemType is String ? itemType : 'tool';

    if (type == 'item.updated' && isTool) {
      return <ProviderActivityObservation>[
        ProviderActivityObservation(
          type: 'model.status',
          status: 'updated',
          title: 'Tool status updated',
          activityId: _activityId(
            itemMap['id'],
            family: 'codex-tool',
            toolKind: toolKind,
            terminal: false,
            reusePending: true,
          ),
          details: {
            ..._toolDetails(toolKind),
            if (itemMap['id'] is! String || (itemMap['id'] as String).isEmpty)
              'identifierSource': 'generated',
          },
        ),
      ];
    }
    if (type == 'item.failed' && isTool) {
      return <ProviderActivityObservation>[
        ProviderActivityObservation(
          type: 'tool.failed',
          status: 'failed',
          title: 'Tool failed',
          activityId: _activityId(
            itemMap['id'],
            family: 'codex-tool',
            toolKind: toolKind,
            terminal: true,
          ),
          details: _toolDetails(toolKind),
        ),
      ];
    }
    if (type == 'item.started' || type == 'item.completed') {
      if (!isTool) return const [];
      if (itemMap['id'] is! String || (itemMap['id'] as String).isEmpty) {
        if (declarativeMatched) {
          return <ProviderActivityObservation>[
            ProviderActivityObservation(
              type: type == 'item.started' ? 'tool.started' : 'tool.completed',
              status: type == 'item.started' ? 'running' : 'completed',
              title: type == 'item.started' ? 'Running tool' : 'Tool completed',
              activityId: _activityId(
                null,
                family: 'codex-tool',
                toolKind: toolKind,
                terminal: type == 'item.completed',
              ),
              details: {
                ..._toolDetails(toolKind),
                'identifierSource': 'generated',
              },
            ),
          ];
        }
        return const [];
      }
      // The declarative mapping owns normal start/completion events so the
      // adapter does not duplicate them.
      return const [];
    }
    // Codex emits item.updated for non-tool items too (plans, reasoning,
    // messages). Those are expected progress, not an unsupported event.
    if (type == 'item.updated') return const [];
    if (type == 'turn.failed' || type == 'error') {
      return <ProviderActivityObservation>[
        const ProviderActivityObservation(
          type: 'model.status',
          status: 'failed',
          title: 'Provider reported an error',
          details: {'diagnostic': 'provider_error'},
        ),
      ];
    }
    if (const {
      'thread.started',
      'turn.started',
      'turn.completed',
      'item.completed',
    }.contains(type)) {
      return const [];
    }
    return _diagnostic('unsupported_event');
  }

  List<ProviderActivityObservation> _normalizeAgy(
    Map event, {
    required bool declarativeMatched,
  }) {
    final eventName = event['event'];
    if (eventName == 'step_update' && event['step_update'] is Map) {
      final step = event['step_update'] as Map;
      final stepType = step['step_type'];
      // Documented AGY step types: user_input, agent_response, tool and
      // checkpoint. `tool_execution` is still accepted for older captures.
      if (stepType == 'tool' || stepType == 'tool_execution') {
        return _normalizeAgyTool(
          step,
          declarativeMatched: declarativeMatched,
        );
      }
      if (const {
        'agent_response',
        'user_input',
        'checkpoint',
      }.contains(stepType)) {
        return const [];
      }
      return _diagnostic('unsupported_step_type');
    }
    if (eventName == 'result') {
      final result = event['result'];
      final resultMap = result is Map ? result : const <Object?, Object?>{};
      final status = resultMap['status'];
      if (const {'ERROR', 'FAILED', 'FAILURE', 'INVALID'}.contains(status)) {
        return <ProviderActivityObservation>[
          const ProviderActivityObservation(
            type: 'model.status',
            status: 'failed',
            title: 'Provider reported an error',
            details: {'diagnostic': 'provider_error'},
          ),
        ];
      }
      // Cancellation and interruption are reported by the Engine's terminal
      // activity, so they are not repeated here.
      if (const {
        'SUCCESS',
        'COMPLETED',
        'CANCELED',
        'INTERRUPTED',
        'WAITING',
        'RUNNING',
      }.contains(status)) {
        return const [];
      }
      return _diagnostic('unsupported_result_status');
    }
    if (eventName == 'init') return const [];
    return _diagnostic('unsupported_event');
  }

  /// A tool step runs as ACTIVE and then ends with DONE (or COMPLETED in older
  /// captures). The DONE event carries `tool_info.error` when the tool failed.
  /// Pairing uses `tool_id` when present, otherwise the conversation and
  /// `step_index`, which repeat on the start and end events of one step.
  List<ProviderActivityObservation> _normalizeAgyTool(
    Map step, {
    required bool declarativeMatched,
  }) {
    final rawToolInfo = step['tool_info'];
    final toolInfo = rawToolInfo is Map
        ? rawToolInfo
        : const <Object?, Object?>{};
    final rawId = _safeText(step['tool_id']);
    // A tool line that a declarative mapping already matched is owned by that
    // mapping. The adapter only fills in tool lines the profile did not map.
    if (declarativeMatched) return const [];

    final state = step['state'];
    final failed =
        const {'FAILED', 'ERROR', 'ERRORED'}.contains(state) ||
        toolInfo['error'] is Map;
    final completed = state == 'DONE' || state == 'COMPLETED';
    final started = state == 'ACTIVE' && !failed;
    if (!failed && !completed && !started) {
      return declarativeMatched
          ? const []
          : _diagnostic('unsupported_tool_state');
    }

    final toolKind =
        _safeText(step['tool_name']) ?? _safeText(toolInfo['name']) ?? 'tool';
    final index = step['step_index'];
    final terminal = failed || completed;
    final String activityId;
    final String identifierSource;
    if (rawId != null) {
      activityId = rawId;
      identifierSource = 'provider';
    } else if (index is int && index >= 0) {
      final conversation = _safeText(step['conversation_id']) ?? 'session';
      final composed = 'agy-step-$conversation-$index';
      activityId =
          composed.length > 128 ? composed.substring(0, 128) : composed;
      identifierSource = 'step_index';
    } else {
      activityId = _activityId(
        null,
        family: 'agy-tool',
        toolKind: toolKind,
        terminal: terminal,
      );
      identifierSource = 'generated';
    }
    final details = <String, Object?>{
      ..._toolDetails(toolKind),
      if (rawId == null) 'identifierSource': identifierSource,
    };
    final type = failed
        ? 'tool.failed'
        : completed
        ? 'tool.completed'
        : 'tool.started';
    return <ProviderActivityObservation>[
      ProviderActivityObservation(
        type: type,
        status: failed
            ? 'failed'
            : completed
            ? 'completed'
            : 'running',
        title: failed
            ? 'Tool failed'
            : completed
            ? 'Tool completed'
            : 'Running tool',
        activityId: activityId,
        details: details,
      ),
    ];
  }

  Map<String, Object?> _toolDetails(String toolKind) => {
    'toolKind': toolKind.length > 64 ? toolKind.substring(0, 64) : toolKind,
  };

  String _activityId(
    Object? raw, {
    required String family,
    required String toolKind,
    required bool terminal,
    bool reusePending = false,
  }) {
    final id = _safeText(raw);
    if (id != null) {
      return id.length > 128 ? id.substring(0, 128) : id;
    }
    final key = '$family:$toolKind';
    if (!terminal && reusePending) {
      final pending = _pendingFallbackIds[key];
      if (pending != null && pending.isNotEmpty) return pending.first;
    }
    if (terminal) {
      final pending = _pendingFallbackIds[key];
      if (pending != null && pending.isNotEmpty) return pending.removeAt(0);
    }
    final occurrence = (_fallbackCounts[key] ?? 0) + 1;
    _fallbackCounts[key] = occurrence;
    final digest = sha256.convert(utf8.encode('$kind:$key')).toString();
    final generated = '$family-${digest.substring(0, 12)}-$occurrence';
    if (!terminal) {
      _pendingFallbackIds.putIfAbsent(key, () => <String>[]).add(generated);
    }
    return generated;
  }

  List<ProviderActivityObservation> _diagnostic(String reason) {
    if (!_reportedDiagnostics.add(reason)) return const [];
    return <ProviderActivityObservation>[
      ProviderActivityObservation(
        type: 'model.status',
        status: 'updated',
        title: 'Provider activity needs attention',
        details: {'diagnostic': reason},
      ),
    ];
  }

  String? _safeText(Object? value) {
    if (value is! String || value.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) return null;
    return value.length > 128 ? value.substring(0, 128) : value;
  }
}
