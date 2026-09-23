enum StudioNotificationKind {
  completed,
  failed,
  approvalRequired,
  hostOffline,
  accountExpired,
  workerInstallFailed,
  invitationReceived,
}

enum StudioNotificationPriority { high, normal, low }

enum StudioNotificationTarget { run, hosts, workers, accounts, workspace }

class StudioNotification {
  const StudioNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.priority,
    this.projectId,
    this.runId,
    this.target,
    this.read = false,
  });

  final String id;
  final StudioNotificationKind kind;
  final String title;
  final String message;
  final DateTime createdAt;
  final StudioNotificationPriority priority;
  final String? projectId;
  final String? runId;
  final StudioNotificationTarget? target;
  final bool read;

  StudioNotification markRead() => StudioNotification(
        id: id,
        kind: kind,
        title: title,
        message: message,
        createdAt: createdAt,
        priority: priority,
        projectId: projectId,
        runId: runId,
        target: target,
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
    'host.offline' || 'host.stale' => StudioNotificationKind.hostOffline,
    'account.expired' ||
    'credential.expired' =>
      StudioNotificationKind.accountExpired,
    'worker.install.failed' ||
    'worker.install_failed' =>
      StudioNotificationKind.workerInstallFailed,
    'workspace.invitation.received' ||
    'invitation.received' =>
      StudioNotificationKind.invitationReceived,
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
        StudioNotificationKind.hostOffline =>
          'A Host is offline and may need to reconnect.',
        StudioNotificationKind.accountExpired =>
          'An AI Account needs to be re-authenticated.',
        StudioNotificationKind.workerInstallFailed =>
          'A Worker could not be installed on a Host.',
        StudioNotificationKind.invitationReceived =>
          'You received a Workspace invitation.',
      };
  final timestamp =
      DateTime.tryParse(_optionalString(event['timestamp']) ?? '')?.toLocal() ??
          DateTime.now();
  final eventId = _optionalString(event['eventId']) ??
      '$type:${runId ?? projectId ?? 'workspace'}:${timestamp.microsecondsSinceEpoch}';
  final target = switch (kind) {
    StudioNotificationKind.completed ||
    StudioNotificationKind.failed ||
    StudioNotificationKind.approvalRequired =>
      StudioNotificationTarget.run,
    StudioNotificationKind.hostOffline => StudioNotificationTarget.hosts,
    StudioNotificationKind.accountExpired => StudioNotificationTarget.accounts,
    StudioNotificationKind.workerInstallFailed =>
      StudioNotificationTarget.workers,
    StudioNotificationKind.invitationReceived =>
      StudioNotificationTarget.workspace,
  };

  return StudioNotification(
    id: eventId,
    kind: kind,
    title: switch (kind) {
      StudioNotificationKind.completed => 'Run completed',
      StudioNotificationKind.failed => 'Run failed',
      StudioNotificationKind.approvalRequired => 'Action needed',
      StudioNotificationKind.hostOffline => 'Host offline',
      StudioNotificationKind.accountExpired => 'AI Account expired',
      StudioNotificationKind.workerInstallFailed => 'Worker install failed',
      StudioNotificationKind.invitationReceived => 'Invitation received',
    },
    message: message,
    createdAt: timestamp,
    priority: switch (kind) {
      StudioNotificationKind.approvalRequired ||
      StudioNotificationKind.failed ||
      StudioNotificationKind.accountExpired =>
        StudioNotificationPriority.high,
      StudioNotificationKind.hostOffline ||
      StudioNotificationKind.workerInstallFailed ||
      StudioNotificationKind.invitationReceived =>
        StudioNotificationPriority.normal,
      StudioNotificationKind.completed => StudioNotificationPriority.low,
    },
    projectId: projectId,
    runId: runId,
    target: target,
  );
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
