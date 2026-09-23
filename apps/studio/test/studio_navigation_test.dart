import 'package:flutter_test/flutter_test.dart';

import 'package:conclave_studio/src/navigation/studio_navigation.dart';

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
  });

  test('each browser tab can own an independent navigation state', () {
    final firstTab =
        StudioNavigation.fromUri(Uri.parse('/projects/project-1/chats/chat-a'));
    final secondTab =
        StudioNavigation.fromUri(Uri.parse('/projects/project-2/chats/chat-b'));

    expect(firstTab, isNot(secondTab));
    expect(firstTab.chatId, isNot(secondTab.chatId));
  });
}
