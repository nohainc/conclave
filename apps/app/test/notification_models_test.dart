import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/notifications/notification_models.dart';

void main() {
  test('only meaningful realtime states create notifications', () {
    expect(isMeaningfulRealtimeNotification('workstream.needs_input'), isTrue);
    expect(isMeaningfulRealtimeNotification('workstream.completed'), isTrue);
    expect(isMeaningfulRealtimeNotification('workstream.recovery.required'),
        isTrue);
    expect(isMeaningfulRealtimeNotification('workflow_run.completed'), isTrue);
    expect(isMeaningfulRealtimeNotification('project.invitation.received'),
        isTrue);
    expect(isMeaningfulRealtimeNotification('discussion.message.created'),
        isFalse);
    expect(
        isMeaningfulRealtimeNotification('workstream.lease.status'), isFalse);
  });

  test('maps Workflow Run events to normalized notification', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-1',
      'type': 'workflow_run.completed',
      'timestamp': '2026-09-23T12:00:00Z',
      'projectId': 'project-1',
      'runId': 'run-1',
      'payload': {'summary': 'Verification passed.'},
    });

    expect(notification, isNotNull);
    expect(notification!.kind, AxNotificationKind.workflowRunCompleted);
    expect(notification.title, 'Workflow Run completed');
    expect(notification.message, 'Verification passed.');
    expect(notification.read, isFalse);
    expect(notification.projectId, 'project-1');
    expect(notification.runId, 'run-1');
    expect(notification.target, AxNotificationTarget.workflowRun);
    expect(notification.priority, AxNotificationPriority.low);
  });

  test('maps Workstream input events to normalized workstream notification',
      () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-ws-1',
      'type': 'workstream.needs_input',
      'projectId': 'project-1',
      'workstreamId': 'ws-auth',
      'payload': {'prompt': 'Approve OAuth provider selection.'},
    });

    expect(notification, isNotNull);
    expect(notification!.kind, AxNotificationKind.workstreamNeedsInput);
    expect(notification.title, 'Workstream needs input');
    expect(notification.message, 'Approve OAuth provider selection.');
    expect(notification.projectId, 'project-1');
    expect(notification.workstreamId, 'ws-auth');
    expect(notification.target, AxNotificationTarget.workstream);
    expect(notification.priority, AxNotificationPriority.high);
  });

  test('maps approval events and ignores progress', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-2',
      'type': 'workflow_run.approval_required',
      'runId': 'run-2',
      'payload': {'prompt': 'Choose the deployment target.'},
    });
    expect(notification?.kind, AxNotificationKind.workflowRunNeedsApproval);
    expect(notification?.message, 'Choose the deployment target.');
    expect(
      notificationFromRealtimeEvent({'type': 'assignment.progress'}),
      isNull,
    );
  });

  test(
      'maps operational attention events to prioritized normalized destinations',
      () {
    final events = <Map<String, dynamic>>[
      {'type': 'workspace.offline'},
      {
        'type': 'worker.credential.expired',
        'payload': {'workspaceId': 'workspace-1', 'workerId': 'worker-1'},
      },
      {
        'type': 'worker.install.failed',
        'payload': {'workspace_id': 'workspace-2', 'worker_id': 'worker-2'},
      },
      {'type': 'project.invitation.received'},
    ];
    final notifications = events
        .map(notificationFromRealtimeEvent)
        .whereType<AxNotification>()
        .toList();

    expect(notifications.map((item) => item.title), [
      'Workspace offline',
      'Worker connection expired',
      'Worker connection failed',
      'Invitation received',
    ]);
    expect(notifications[0].target, AxNotificationTarget.workspaces);
    expect(notifications[0].kind, AxNotificationKind.workspaceOffline);

    expect(notifications[1].priority, AxNotificationPriority.high);
    expect(notifications[1].target, AxNotificationTarget.workspace);
    expect(notifications[1].kind, AxNotificationKind.workerCredentialProblem);
    expect(notifications[1].workspaceId, 'workspace-1');
    expect(notifications[1].workerId, 'worker-1');

    expect(notifications[2].target, AxNotificationTarget.workspace);
    expect(notifications[2].kind, AxNotificationKind.workerInstallFailed);
    expect(notifications[2].workspaceId, 'workspace-2');
    expect(notifications[2].workerId, 'worker-2');

    expect(notifications[3].target, AxNotificationTarget.project);
    expect(notifications[3].kind, AxNotificationKind.projectInvitationReceived);
  });
}
