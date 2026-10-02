import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/navigation/ax_navigation.dart';

void main() {
  test('parses and serializes project, Workstream, and run deep links', () {
    final workstream = AxNavigation.fromUri(
        Uri.parse('/projects/project-1/workstreams/workstream-2'));
    expect(workstream.kind, AxRouteKind.workstream);
    expect(workstream.workstreamId, 'workstream-2');
    expect(workstream.toUri().path,
        '/projects/project-1/workstreams/workstream-2');

    final legacyRun =
        AxNavigation.fromUri(Uri.parse('/projects/project-1/runs/run-3'));
    expect(legacyRun.kind, AxRouteKind.run);
    expect(legacyRun.toUri().path, '/projects/project-1/runs/run-3');

    final canonicalRun = AxNavigation.fromUri(
        Uri.parse('/projects/project-1/workstreams/workstream-2/runs/run-3'));
    expect(canonicalRun.kind, AxRouteKind.run);
    expect(canonicalRun.projectId, 'project-1');
    expect(canonicalRun.workstreamId, 'workstream-2');
    expect(canonicalRun.runId, 'run-3');
    expect(canonicalRun.toUri().path,
        '/projects/project-1/workstreams/workstream-2/runs/run-3');

    final profile = AxNavigation.fromUri(Uri.parse('/settings/profile'));
    expect(profile.kind, AxRouteKind.profileSecurity);
    expect(profile.toUri().path, '/settings/profile');
  });

  test('has stable routes for every major application section', () {
    final routes = <AxNavigation>[
      const AxNavigation.home(),
      const AxNavigation.projects(),
      const AxNavigation.workspaces(),
      const AxNavigation.profileSecurity(),
    ];

    for (final route in routes) {
      expect(AxNavigation.fromUri(route.toUri()), route);
    }
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
