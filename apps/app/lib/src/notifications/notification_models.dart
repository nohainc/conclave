enum StudioNotificationKind { completed, failed, approvalRequired }

class StudioNotification {
  const StudioNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.createdAt,
    this.projectId,
    this.runId,
    this.read = false,
  });

  final String id;
  final StudioNotificationKind kind;
  final String title;
  final String message;
  final DateTime createdAt;
  final String? projectId;
  final String? runId;
  final bool read;

  StudioNotification markRead() => StudioNotification(
        id: id,
        kind: kind,
        title: title,
        message: message,
        createdAt: createdAt,
        projectId: projectId,
        runId: runId,
        read: true,
      );
}

StudioNotification? notificationFromRealtimeEvent(
  Map<String, dynamic> event,
) {
  final type = event['type'];
  if (type is! String) return null;
  final kind = switch (type) {
    'run.completed' ||
    'assignment.completed' =>
      StudioNotificationKind.completed,
    'run.failed' ||
    'task.failed' ||
    'assignment.failed' =>
      StudioNotificationKind.failed,
    'run.input_required' ||
    'run.approval_required' =>
      StudioNotificationKind.approvalRequired,
    _ => null,
  };
  if (kind == null) return null;

  final payload = event['payload'];
  final payloadMap = payload is Map
      ? Map<String, dynamic>.from(payload)
      : const <String, dynamic>{};
  final runId =
      _optionalString(event['runId']) ?? _optionalString(payloadMap['runId']);
  final projectId = _optionalString(event['projectId']) ??
      _optionalString(payloadMap['projectId']);
  final message = _optionalString(payloadMap['prompt']) ??
      _optionalString(payloadMap['summary']) ??
      _optionalString(payloadMap['error']) ??
      switch (kind) {
        StudioNotificationKind.completed => 'The Run is ready to review.',
        StudioNotificationKind.failed => 'The Run needs attention.',
        StudioNotificationKind.approvalRequired =>
          'A response is needed before the Run can continue.',
      };
  final timestamp =
      DateTime.tryParse(_optionalString(event['timestamp']) ?? '')?.toLocal() ??
          DateTime.now();
  final eventId = _optionalString(event['eventId']) ??
      '$type:${runId ?? projectId ?? 'workspace'}:${timestamp.microsecondsSinceEpoch}';

  return StudioNotification(
    id: eventId,
    kind: kind,
    title: switch (kind) {
      StudioNotificationKind.completed => 'Run completed',
      StudioNotificationKind.failed => 'Run failed',
      StudioNotificationKind.approvalRequired => 'Action needed',
    },
    message: message,
    createdAt: timestamp,
    projectId: projectId,
    runId: runId,
  );
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
