import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/notifications/notification_models.dart';

void main() {
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
    expect(notification?.kind, StudioNotificationKind.approvalRequired);
    expect(notification?.message, 'Choose the deployment target.');
    expect(
      notificationFromRealtimeEvent({'type': 'assignment.progress'}),
      isNull,
    );
  });

  test('maps operational attention events to prioritized destinations', () {
    final events = <Map<String, dynamic>>[
      {'type': 'host.offline'},
      {'type': 'credential.expired'},
      {'type': 'worker.install.failed'},
      {'type': 'workspace.invitation.received'},
    ];
    final notifications = events
        .map(notificationFromRealtimeEvent)
        .whereType<StudioNotification>()
        .toList();

    expect(notifications.map((item) => item.title), [
      'Host offline',
      'AI Account expired',
      'Worker install failed',
      'Invitation received',
    ]);
    expect(notifications[0].target, StudioNotificationTarget.hosts);
    expect(notifications[1].priority, StudioNotificationPriority.high);
    expect(notifications[2].target, StudioNotificationTarget.workers);
    expect(notifications[3].target, StudioNotificationTarget.workspace);
  });
}
