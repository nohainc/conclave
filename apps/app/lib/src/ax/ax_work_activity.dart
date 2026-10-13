import 'package:flutter/foundation.dart';

import 'ax_work_models.dart';

/// Safe, provider-neutral activity projected from a realtime Worker event.
///
/// The Cloud contract already strips raw provider output. The AX model keeps
/// only fields intended for the operational timeline and never treats a
/// percentage as completion progress.
class AxWorkActivity {
  const AxWorkActivity({
    required this.eventId,
    required this.assignmentId,
    required this.attemptId,
    required this.executionId,
    required this.workerId,
    required this.activitySequence,
    required this.streamSequence,
    required this.type,
    required this.status,
    required this.title,
    required this.timestamp,
    this.activityId,
    this.details = const <String, Object?>{},
  });

  final String eventId;
  final String assignmentId;
  final String attemptId;
  final String executionId;
  final String workerId;
  final int activitySequence;
  final int streamSequence;
  final String type;
  final String status;
  final String title;
  final DateTime timestamp;
  final String? activityId;
  final Map<String, Object?> details;

  bool get isRunning => status == 'running' || status == 'updated';

  bool get isFinished =>
      status == 'completed' ||
      status == 'failed' ||
      status == 'cancelled' ||
      status == 'interrupted' ||
      type == 'tool.completed' ||
      type == 'tool.failed' ||
      type == 'execution.completed' ||
      type == 'execution.failed' ||
      type == 'execution.cancelled';

  bool get isTerminalExecution =>
      type == 'execution.completed' ||
      type == 'execution.failed' ||
      type == 'execution.cancelled';

  bool get isError =>
      status == 'failed' || status == 'interrupted' || type == 'tool.failed';

  bool get isReplaceable => type == 'model.status' || type == 'message.updated';

  AxWorkActivity copyWith({
    String? type,
    String? status,
    String? title,
    Map<String, Object?>? details,
  }) =>
      AxWorkActivity(
        eventId: eventId,
        assignmentId: assignmentId,
        attemptId: attemptId,
        executionId: executionId,
        workerId: workerId,
        activitySequence: activitySequence,
        streamSequence: streamSequence,
        type: type ?? this.type,
        status: status ?? this.status,
        title: title ?? this.title,
        timestamp: timestamp,
        activityId: activityId,
        details: details ?? this.details,
      );

  AxWorkActivity merge(AxWorkActivity update) => AxWorkActivity(
        eventId: update.eventId,
        assignmentId: assignmentId,
        attemptId: update.attemptId,
        executionId: update.executionId,
        workerId: update.workerId,
        activitySequence: update.activitySequence,
        streamSequence: update.streamSequence,
        type: update.type,
        status: update.status,
        title: update.title,
        timestamp: update.timestamp,
        activityId: update.activityId ?? activityId,
        details: update.details.isEmpty ? details : update.details,
      );

  factory AxWorkActivity.fromRealtimeEvent(
    Map<String, dynamic> event, {
    required String threadId,
  }) {
    if (event['type'] != 'assignment.activity') {
      throw const FormatException('Not a Worker Activity event');
    }
    final eventThreadId = event['threadId'];
    if (eventThreadId != threadId) {
      throw const FormatException('Worker Activity belongs to another Thread');
    }
    final payload = event['payload'];
    if (payload is! Map) {
      throw const FormatException('Worker Activity payload is invalid');
    }
    final values = Map<String, dynamic>.from(payload);
    String requiredString(String key) {
      final value = values[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Worker Activity $key is required');
      }
      return value.trim();
    }

    final eventId = event['eventId'];
    final streamSequence = event['sequence'];
    final activitySequence = values['activitySequence'];
    final timestamp = event['timestamp'];
    final assignmentId = event['assignmentId'] ?? values['entityId'];
    final attemptId = event['attemptId'];
    if (eventId is! String || eventId.trim().isEmpty) {
      throw const FormatException('Worker Activity eventId is required');
    }
    if (assignmentId is! String || assignmentId.trim().isEmpty) {
      throw const FormatException('Worker Activity assignmentId is required');
    }
    if (attemptId is! String || attemptId.trim().isEmpty) {
      throw const FormatException('Worker Activity attemptId is required');
    }
    if (activitySequence is! int || activitySequence < 1) {
      throw const FormatException('Worker Activity sequence is invalid');
    }
    if (streamSequence is! int || streamSequence < 0) {
      throw const FormatException('Worker Activity stream sequence is invalid');
    }
    if (timestamp is! String) {
      throw const FormatException('Worker Activity timestamp is required');
    }
    final parsedTimestamp = DateTime.tryParse(timestamp);
    if (parsedTimestamp == null) {
      throw const FormatException('Worker Activity timestamp is invalid');
    }
    final rawDetails = values['details'];
    final details = <String, Object?>{};
    if (rawDetails is Map) {
      for (final entry in rawDetails.entries) {
        if (entry.key is String &&
            (entry.value == null ||
                entry.value is String ||
                entry.value is num ||
                entry.value is bool)) {
          details[entry.key as String] = entry.value;
        }
      }
    }
    return AxWorkActivity(
      eventId: eventId.trim(),
      assignmentId: assignmentId.trim(),
      attemptId: attemptId.trim(),
      executionId: requiredString('executionId'),
      workerId: requiredString('workerId'),
      activitySequence: activitySequence,
      streamSequence: streamSequence,
      type: requiredString('activityType'),
      status: requiredString('activityStatus'),
      title: requiredString('title'),
      timestamp: parsedTimestamp.toLocal(),
      activityId: values['activityId'] is String
          ? (values['activityId'] as String).trim()
          : null,
      details: Map.unmodifiable(details),
    );
  }

  factory AxWorkActivity.fromHistory(Map<String, dynamic> values) {
    String requiredString(String key) {
      final value = values[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('Worker Activity $key is required');
      }
      return value.trim();
    }

    final activitySequence = values['activitySequence'];
    final timestamp = values['timestamp'];
    if (activitySequence is! int ||
        activitySequence < 1 ||
        timestamp is! String) {
      throw const FormatException('Worker Activity history is invalid');
    }
    final parsedTimestamp = DateTime.tryParse(timestamp);
    if (parsedTimestamp == null) {
      throw const FormatException(
          'Worker Activity history timestamp is invalid');
    }
    final details = <String, Object?>{};
    final rawDetails = values['details'];
    if (rawDetails is Map) {
      for (final entry in rawDetails.entries) {
        if (entry.key is String &&
            (entry.value == null ||
                entry.value is String ||
                entry.value is num ||
                entry.value is bool)) {
          details[entry.key as String] = entry.value;
        }
      }
    }
    return AxWorkActivity(
      eventId: requiredString('eventId'),
      assignmentId: requiredString('assignmentId'),
      attemptId: requiredString('attemptId'),
      executionId: requiredString('executionId'),
      workerId: requiredString('workerId'),
      activitySequence: activitySequence,
      streamSequence: 0,
      type: requiredString('activityType'),
      status: requiredString('activityStatus'),
      title: requiredString('title'),
      timestamp: parsedTimestamp.toLocal(),
      activityId: values['activityId'] is String
          ? (values['activityId'] as String).trim()
          : null,
      details: Map.unmodifiable(details),
    );
  }
}

/// Thread-local activity projection. It is intentionally separate from Work
/// request/result state so operational events cannot mutate conversation text.
class AxWorkActivityStore extends ChangeNotifier {
  static const maxActivitiesPerAssignment = 512;
  static const maxRememberedEventIds = 4096;

  final _activities = <String, List<AxWorkActivity>>{};
  final _eventIds = <String>{};

  List<AxWorkActivity> forRequest(AxWorkRequest request) {
    final assignmentIds = {
      ...request.steps.map((step) => step.assignmentId).whereType<String>(),
      ...request.turns.map((turn) => turn.assignmentId).whereType<String>(),
    };
    if (assignmentIds.isEmpty) return const [];
    final result = <AxWorkActivity>[];
    final requestIsTerminal = const {
      'completed',
      'failed',
      'cancelled',
      'timed_out',
      'lost',
    }.contains(request.status);
    for (final assignmentId in assignmentIds) {
      final activities = _activities[assignmentId] ?? const [];
      final historical = request.activityHistory
          .where((item) => item['assignmentId'] == assignmentId)
          .map((item) {
        try {
          return AxWorkActivity.fromHistory(item);
        } on FormatException {
          return null;
        }
      }).whereType<AxWorkActivity>();
      final merged = <String, AxWorkActivity>{
        for (final activity in historical) activity.eventId: activity,
        for (final activity in activities) activity.eventId: activity,
      };
      if (!requestIsTerminal) {
        result.addAll(merged.values);
        continue;
      }
      result.addAll(merged.values.map((activity) {
        if (activity.isFinished) return activity;
        return activity.copyWith(
          status: 'interrupted',
          title: 'Activity ended when the execution terminated',
          details: {
            ...activity.details,
            'reconciled': true,
          },
        );
      }));
    }
    result.sort(_compare);
    return List.unmodifiable(result);
  }

  List<AxWorkActivity> forAssignment(String assignmentId) =>
      List.unmodifiable(_activities[assignmentId] ?? const []);

  bool handle(Map<String, dynamic> event, {required String threadId}) {
    if (event['type'] != 'assignment.activity') return false;
    late final AxWorkActivity activity;
    try {
      activity = AxWorkActivity.fromRealtimeEvent(event, threadId: threadId);
    } on FormatException {
      return false;
    }
    if (!_eventIds.add(activity.eventId)) return false;
    if (_eventIds.length > maxRememberedEventIds) {
      _eventIds.remove(_eventIds.first);
    }
    final list = _activities.putIfAbsent(activity.assignmentId, () => []);
    final matchingIndex = _matchingIndex(list, activity);
    if (matchingIndex >= 0) {
      final current = list[matchingIndex];
      if (_compare(current, activity) > 0) return false;
      list[matchingIndex] = current.merge(activity);
    } else {
      list.add(activity);
    }
    list.sort(_compare);
    if (list.length > maxActivitiesPerAssignment) {
      list.removeRange(0, list.length - maxActivitiesPerAssignment);
    }
    notifyListeners();
    return true;
  }

  void clear() {
    if (_activities.isEmpty && _eventIds.isEmpty) return;
    _activities.clear();
    _eventIds.clear();
    notifyListeners();
  }

  int _matchingIndex(List<AxWorkActivity> list, AxWorkActivity incoming) {
    if (incoming.activityId != null && incoming.activityId!.isNotEmpty) {
      final index = list.indexWhere((item) =>
          item.activityId == incoming.activityId &&
          item.attemptId == incoming.attemptId);
      if (index >= 0) return index;
    }
    if (incoming.isReplaceable) {
      for (var index = list.length - 1; index >= 0; index--) {
        final item = list[index];
        if (item.attemptId == incoming.attemptId && item.isReplaceable) {
          return index;
        }
      }
    }
    return -1;
  }

  int _compare(AxWorkActivity left, AxWorkActivity right) {
    final stream = left.streamSequence.compareTo(right.streamSequence);
    if (stream != 0) return stream;
    final activity = left.activitySequence.compareTo(right.activitySequence);
    if (activity != 0) return activity;
    return left.eventId.compareTo(right.eventId);
  }
}
