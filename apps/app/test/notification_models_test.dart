import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/notifications/notification_models.dart';

void main() {
  test('only meaningful realtime states create notifications', () {
    expect(isMeaningfulRealtimeNotification('workstream.needs_input'), isTrue);
    expect(isMeaningfulRealtimeNotification('workstream.completed'), isTrue);
    expect(isMeaningfulRealtimeNotification('workstream.recovery.required'),
        isTrue);
    expect(isMeaningfulRealtimeNotification('discussion.message.created'),
        isFalse);
    expect(
        isMeaningfulRealtimeNotification('workstream.lease.status'), isFalse);
  });
  test('maps terminal Run events to an unread notification', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-1',
      'type': 'run.completed',
      'timestamp': '2026-09-23T12:00:00Z',
      'projectId': 'project-1',
      'runId': 'run-1',
      'payload': {'summary': 'Verification passed.'},
    });

    expect(notification, isNotNull);
    expect(notification!.title, 'Run completed');
    expect(notification.message, 'Verification passed.');
    expect(notification.read, isFalse);
    expect(notification.projectId, 'project-1');
    expect(notification.runId, 'run-1');
  });

  test('maps approval events and ignores progress', () {
    final notification = notificationFromRealtimeEvent({
      'eventId': 'event-2',
      'type': 'run.approval_required',
      'runId': 'run-2',
      'payload': {'prompt': 'Choose the deployment target.'},
    });
    expect(notification?.kind, AxNotificationKind.approvalRequired);
    expect(notification?.message, 'Choose the deployment target.');
    expect(
      notificationFromRealtimeEvent({'type': 'assignment.progress'}),
      isNull,
    );
  });

  test('maps operational attention events to prioritized destinations', () {
    final events = <Map<String, dynamic>>[
      {'type': 'workspace.offline'},
      {
        'type': 'credential.expired',
        'payload': {'workspaceId': 'workspace-1', 'workerId': 'worker-1'},
      },
      {
        'type': 'worker.install.failed',
        'payload': {'workspace_id': 'workspace-2', 'worker_id': 'worker-2'},
      },
      {'type': 'workspace.invitation.received'},
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
    expect(notifications[1].priority, AxNotificationPriority.high);
    expect(notifications[1].target, AxNotificationTarget.workspace);
    expect(notifications[1].workspaceId, 'workspace-1');
    expect(notifications[1].workerId, 'worker-1');
    expect(notifications[2].target, AxNotificationTarget.workspace);
    expect(notifications[2].workspaceId, 'workspace-2');
    expect(notifications[2].workerId, 'worker-2');
    expect(notifications[3].target, AxNotificationTarget.workspace);
  });
}
