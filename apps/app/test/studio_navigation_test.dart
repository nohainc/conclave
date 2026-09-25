import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/navigation/studio_navigation.dart';

void main() {
  test('parses and serializes project, Workstream, and run deep links', () {
    final chat =
        StudioNavigation.fromUri(Uri.parse('/projects/project-1/chats/chat-2'));
    expect(chat.kind, StudioRouteKind.chat);
    expect(chat.projectId, 'project-1');
    expect(chat.chatId, 'chat-2');
    expect(chat.toUri().path, '/projects/project-1/chats/chat-2');

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
      const StudioNavigation.hosts(),
      const StudioNavigation.workers(),
      const StudioNavigation.profileSecurity(),
    ];

    for (final route in routes) {
      expect(StudioNavigation.fromUri(route.toUri()), route);
    }
  });

  test('uses canonical Execution routes and preserves legacy aliases', () {
    const workspace = StudioNavigation.hosts();
    expect(workspace.toUri().path, '/execution/workspaces');
    expect(StudioNavigation.fromUri(Uri.parse('/execution')), workspace);
    expect(StudioNavigation.fromUri(Uri.parse('/execution/workspaces')),
        workspace);
    expect(StudioNavigation.fromUri(Uri.parse('/workspaces')), workspace);
    expect(StudioNavigation.fromUri(Uri.parse('/hosts')), workspace);

    const workers = StudioNavigation.workers();
    expect(workers.toUri().path, '/execution/workers');
    expect(StudioNavigation.fromUri(Uri.parse('/execution/workers')), workers);
    expect(StudioNavigation.fromUri(Uri.parse('/workspaces/workers')), workers);
    expect(StudioNavigation.fromUri(Uri.parse('/hosts/workers')), workers);
    expect(StudioNavigation.fromUri(Uri.parse('/workers')), workers);
    expect(StudioNavigation.fromUri(Uri.parse('/workspaces?tab=workers')),
        workers);
    expect(StudioNavigation.fromUri(Uri.parse('/hosts?tab=workers')), workers);

  });

  test('each browser tab can own an independent navigation state', () {
    final firstTab =
        StudioNavigation.fromUri(Uri.parse('/projects/project-1/chats/chat-a'));
    final secondTab =
        StudioNavigation.fromUri(Uri.parse('/projects/project-2/chats/chat-b'));

    expect(firstTab, isNot(secondTab));
    expect(firstTab.chatId, isNot(secondTab.chatId));
  });

  test('preserves a deep link through the signed-out route', () {
    final login = StudioNavigation.fromUri(
        Uri.parse('/login?returnTo=%2Fprojects%2Fproject-1%2Fchats%2Fchat-2'));

    expect(login.kind, StudioRouteKind.login);
    expect(login.loginReturnTo, '/projects/project-1/chats/chat-2');
    expect(login.toUri().queryParameters['returnTo'],
        '/projects/project-1/chats/chat-2');
  });
}
