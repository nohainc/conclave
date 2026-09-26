enum StudioNotificationKind {
  completed,
  failed,
  approvalRequired,
  workspaceOffline,
  workerCredentialProblem,
  workerInstallFailed,
  invitationReceived,
}

enum StudioNotificationPriority { high, normal, low }

enum StudioNotificationTarget { run, workspaces, workspace }

/// Filters realtime noise from actionable team notifications. Progress,
/// discussion, queue, checkout, and lease updates update read models but do
/// not interrupt the user.
bool isMeaningfulRealtimeNotification(String type) => {
      'run.input_required',
      'run.approval_required',
      'workstream.needs_input',
      'workstream.completed',
      'workstream.failed',
      'workstream.account.problem',
      'workstream.grant.problem',
      'workstream.recovery.required',
      'run.completed',
      'run.failed',
      'assignment.failed',
      'account.expired',
      'credential.expired',
      'worker.install.failed',
      'worker.install_failed',
    }.contains(type);

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
    this.workspaceId,
    this.workerId,
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
  final String? workspaceId;
  final String? workerId;
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
        workspaceId: workspaceId,
        workerId: workerId,
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
    'run.approval_required' ||
    'workstream.needs_input' =>
      StudioNotificationKind.approvalRequired,
    'workstream.completed' => StudioNotificationKind.completed,
    'workstream.failed' ||
    'workstream.grant.problem' ||
    'workstream.recovery.required' =>
      StudioNotificationKind.failed,
    'workstream.account.problem' =>
      StudioNotificationKind.workerCredentialProblem,
    'host.offline' || 'host.stale' => StudioNotificationKind.workspaceOffline,
    'account.expired' ||
    'credential.expired' =>
      StudioNotificationKind.workerCredentialProblem,
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
  final workspaceId = _optionalString(event['workspaceId']) ??
      _optionalString(event['workspace_id']) ??
      _optionalString(payloadMap['workspaceId']) ??
      _optionalString(payloadMap['workspace_id']);
  final workerId = _optionalString(event['workerId']) ??
      _optionalString(event['worker_id']) ??
      _optionalString(payloadMap['workerId']) ??
      _optionalString(payloadMap['worker_id']);
  final message = _optionalString(payloadMap['prompt']) ??
      _optionalString(payloadMap['summary']) ??
      _optionalString(payloadMap['error']) ??
      switch (kind) {
        StudioNotificationKind.completed => 'The Run is ready to review.',
        StudioNotificationKind.failed => 'The Run needs attention.',
        StudioNotificationKind.approvalRequired =>
          'A response is needed before the Run can continue.',
        StudioNotificationKind.workspaceOffline =>
          'A Workspace is offline and may need to reconnect.',
        StudioNotificationKind.workerCredentialProblem =>
          'A Worker connection needs to be re-authenticated.',
        StudioNotificationKind.workerInstallFailed =>
          'A Worker could not connect to a Workspace.',
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
      StudioNotificationKind.workspaceOffline =>
        StudioNotificationTarget.workspaces,
    StudioNotificationKind.workerCredentialProblem =>
      StudioNotificationTarget.workspace,
    StudioNotificationKind.workerInstallFailed =>
      StudioNotificationTarget.workspace,
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
      StudioNotificationKind.workspaceOffline => 'Workspace offline',
      StudioNotificationKind.workerCredentialProblem =>
        'Worker connection expired',
      StudioNotificationKind.workerInstallFailed => 'Worker connection failed',
      StudioNotificationKind.invitationReceived => 'Invitation received',
    },
    message: message,
    createdAt: timestamp,
    priority: switch (kind) {
      StudioNotificationKind.approvalRequired ||
      StudioNotificationKind.failed ||
      StudioNotificationKind.workerCredentialProblem =>
        StudioNotificationPriority.high,
      StudioNotificationKind.workspaceOffline ||
      StudioNotificationKind.workerInstallFailed ||
      StudioNotificationKind.invitationReceived =>
        StudioNotificationPriority.normal,
      StudioNotificationKind.completed => StudioNotificationPriority.low,
    },
    projectId: projectId,
    runId: runId,
    workspaceId: workspaceId,
    workerId: workerId,
    target: target,
  );
}

String? _optionalString(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
