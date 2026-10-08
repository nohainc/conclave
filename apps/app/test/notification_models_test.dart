import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/notifications/notification_models.dart';

void main() {
  test('only meaningful realtime states create notifications', () {
    expect(isMeaningfulRealtimeNotification('thread.needs_input'), isTrue);
    expect(isMeaningfulRealtimeNotification('thread.completed'), isTrue);
    expect(
        isMeaningfulRealtimeNotification('thread.recovery.required'), isTrue);
    expect(isMeaningfulRealtimeNotification('workflow_run.completed'), isTrue);
    expect(
        isMeaningfulRealtimeNotification('space.invitation.received'), isTrue);
    expect(isMeaningfulRealtimeNotification('discussion.message.created'),
        isFalse);
    expect(isMeaningfulRealtimeNotification('thread.lease.status'), isFalse);
  });

  test('maps Workflow Run events to normalized notification', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-1',
      'type': 'workflow_run.completed',
      'timestamp': '2026-09-23T12:00:00Z',
      'spaceId': 'space-1',
      'runId': 'run-1',
      'payload': {'summary': 'Verification passed.'},
    });

    expect(notification, isNotNull);
    expect(notification!.kind, AxNotificationKind.workflowRunCompleted);
    expect(notification.title, 'Workflow Run completed');
    expect(notification.message, 'Verification passed.');
    expect(notification.read, isFalse);
    expect(notification.spaceId, 'space-1');
    expect(notification.runId, 'run-1');
    expect(notification.target, AxNotificationTarget.workflowRun);
    expect(notification.priority, AxNotificationPriority.low);
  });

  test('maps Thread input events to normalized thread notification', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-ws-1',
      'type': 'thread.needs_input',
      'spaceId': 'space-1',
      'threadId': 'ws-auth',
      'payload': {'prompt': 'Approve OAuth provider selection.'},
    });

    expect(notification, isNotNull);
    expect(notification!.kind, AxNotificationKind.threadNeedsInput);
    expect(notification.title, 'Thread needs input');
    expect(notification.message, 'Approve OAuth provider selection.');
    expect(notification.spaceId, 'space-1');
    expect(notification.threadId, 'ws-auth');
    expect(notification.target, AxNotificationTarget.thread);
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
      {'type': 'space.invitation.received'},
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

    expect(notifications[3].target, AxNotificationTarget.space);
    expect(notifications[3].kind, AxNotificationKind.spaceInvitationReceived);
  });
}
