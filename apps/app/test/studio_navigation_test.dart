import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_app/src/navigation/studio_navigation.dart';

void main() {
  test('parses and serializes project, chat, and run deep links', () {
    final chat =
        StudioNavigation.fromUri(Uri.parse('/projects/project-1/chats/chat-2'));
    expect(chat.kind, StudioRouteKind.chat);
    expect(chat.projectId, 'project-1');
    expect(chat.chatId, 'chat-2');
    expect(chat.toUri().path, '/projects/project-1/chats/chat-2');

    final run =
        StudioNavigation.fromUri(Uri.parse('/projects/project-1/runs/run-3'));
    expect(run.kind, StudioRouteKind.run);
    expect(run.toUri().path, '/projects/project-1/runs/run-3');

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
      const StudioNavigation.accounts(),
      const StudioNavigation.usage(),
      const StudioNavigation.workspaceSettings(),
      const StudioNavigation.profileSecurity(),
    ];

    for (final route in routes) {
      expect(StudioNavigation.fromUri(route.toUri()), route);
    }
  });

  test('uses the Workspace route while accepting legacy Host links', () {
    const workspace = StudioNavigation.hosts();
    expect(workspace.toUri().path, '/workspaces');
    expect(StudioNavigation.fromUri(Uri.parse('/workspaces')), workspace);
    expect(StudioNavigation.fromUri(Uri.parse('/hosts')), workspace);
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
