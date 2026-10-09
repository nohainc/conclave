import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/navigation/ax_navigation.dart';

void main() {
  test('retired product deep links do not masquerade as renamed routes', () {
    for (final path in [
      '/projects/S',
      '/projects/S/workstreams/T',
      '/spaces/S/workstreams/T'
    ]) {
      expect(AxNavigation.fromUri(Uri.parse(path)).kind, AxRouteKind.home);
    }
    expect(AxNavigation.fromUri(Uri.parse('/spaces/S/threads/T')).toUri().path,
        '/spaces/S/threads/T');
  });
  test('parses and serializes space, Thread, and run deep links', () {
    final thread =
        AxNavigation.fromUri(Uri.parse('/spaces/space-1/threads/thread-2'));
    expect(thread.kind, AxRouteKind.thread);
    expect(thread.threadId, 'thread-2');
    expect(thread.toUri().path, '/spaces/space-1/threads/thread-2');

    final legacyRun =
        AxNavigation.fromUri(Uri.parse('/spaces/space-1/runs/run-3'));
    expect(legacyRun.kind, AxRouteKind.run);
    expect(legacyRun.toUri().path, '/spaces/space-1/runs/run-3');

    final canonicalRun = AxNavigation.fromUri(
        Uri.parse('/spaces/space-1/threads/thread-2/runs/run-3'));
    expect(canonicalRun.kind, AxRouteKind.run);
    expect(canonicalRun.spaceId, 'space-1');
    expect(canonicalRun.threadId, 'thread-2');
    expect(canonicalRun.runId, 'run-3');
    expect(canonicalRun.toUri().path,
        '/spaces/space-1/threads/thread-2/runs/run-3');

    final profile = AxNavigation.fromUri(Uri.parse('/settings/profile'));
    expect(profile.kind, AxRouteKind.profileSecurity);
    expect(profile.toUri().path, '/settings/profile');
  });

  test('has stable routes for every major application section', () {
    final routes = <AxNavigation>[
      const AxNavigation.home(),
      const AxNavigation.spaces(),
      const AxNavigation.archivedSpaces(),
      const AxNavigation.workflows(),
      const AxNavigation.workspaces(),
      const AxNavigation.profileSecurity(),
    ];

    for (final route in routes) {
      expect(AxNavigation.fromUri(route.toUri()), route);
    }
    expect(AxNavigation.fromUri(Uri.parse('/archived-spaces')).kind,
        AxRouteKind.archivedSpaces);
  });

  test('preserves desktop auth approval through the browser sign-in route', () {
    final approval = AxNavigation.fromUri(
      Uri.parse('/desktop-auth/approve?intentId=intent-123'),
    );
    expect(approval.kind, AxRouteKind.desktopAuthApproval);
    expect(approval.desktopAuthIntentId, 'intent-123');
    final login = AxNavigation.login(returnTo: approval.toUri().toString());
    final restored = AxNavigation.fromUri(Uri.parse(login.toUri().toString()));
    expect(AxNavigation.fromUri(Uri.parse(restored.loginReturnTo!)), approval);
  });
}
