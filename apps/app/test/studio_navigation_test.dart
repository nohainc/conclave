import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/navigation/studio_navigation.dart';

void main() {
  test('parses and serializes project, Workstream, and run deep links', () {
    final workstream = StudioNavigation.fromUri(
        Uri.parse('/projects/project-1/workstreams/workstream-2'));
    expect(workstream.kind, StudioRouteKind.workstream);
    expect(workstream.workstreamId, 'workstream-2');
    expect(workstream.toUri().path,
        '/projects/project-1/workstreams/workstream-2');

    final legacyRun =
        StudioNavigation.fromUri(Uri.parse('/projects/project-1/runs/run-3'));
    expect(legacyRun.kind, StudioRouteKind.run);
    expect(legacyRun.toUri().path, '/projects/project-1/runs/run-3');

    final canonicalRun = StudioNavigation.fromUri(
        Uri.parse('/projects/project-1/workstreams/workstream-2/runs/run-3'));
    expect(canonicalRun.kind, StudioRouteKind.run);
    expect(canonicalRun.projectId, 'project-1');
    expect(canonicalRun.workstreamId, 'workstream-2');
    expect(canonicalRun.runId, 'run-3');
    expect(canonicalRun.toUri().path,
        '/projects/project-1/workstreams/workstream-2/runs/run-3');

    final profile = StudioNavigation.fromUri(Uri.parse('/settings/profile'));
    expect(profile.kind, StudioRouteKind.profileSecurity);
    expect(profile.toUri().path, '/settings/profile');
  });

  test('has stable routes for every major application section', () {
    final routes = <StudioNavigation>[
      const StudioNavigation.home(),
      const StudioNavigation.projects(),
      const StudioNavigation.workspaces(),
      const StudioNavigation.profileSecurity(),
    ];

    for (final route in routes) {
      expect(StudioNavigation.fromUri(route.toUri()), route);
    }
  });

  test('preserves desktop auth approval through the browser sign-in route', () {
    final approval = StudioNavigation.fromUri(
      Uri.parse('/desktop-auth/approve?intentId=intent-123'),
    );
    expect(approval.kind, StudioRouteKind.desktopAuthApproval);
    expect(approval.desktopAuthIntentId, 'intent-123');
    final login = StudioNavigation.login(returnTo: approval.toUri().toString());
    final restored =
        StudioNavigation.fromUri(Uri.parse(login.toUri().toString()));
    expect(
        StudioNavigation.fromUri(Uri.parse(restored.loginReturnTo!)), approval);
  });
}
