import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/app_sidebar.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const owned = AxSpace(
    id: 'owned', name: 'My Space', branch: '', lastActivity: '', role: 'owner');
const shared = AxSpace(
    id: 'shared',
    name: 'Shared Space',
    branch: '',
    lastActivity: '',
    role: 'collaborator',
    hasUnread: true);
const thread = AxThread(
    id: 'thread',
    spaceId: 'owned',
    name: 'Busy Thread',
    lead: '',
    status: 'active',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '',
    hasActiveWork: true);

Finder marker(String owner, String state) => find.descendant(
    of: find.byKey(ValueKey(owner)),
    matching: find.byKey(ValueKey('sidebar-$state-indicator')));

Widget rail(AxShellContext context,
        {bool reduceMotion = false, ValueChanged<AxNavigation>? navigate}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
            body: AppIconRail(
          shellContext: context,
          onNavigateTo: navigate ?? (_) {},
          onOpenDrawer: () {},
          onLogout: () {},
          onOpenAbout: () {},
          onOpenExternal: (_) {},
        )),
      ),
    );

void main() {
  testWidgets(
      'collapsed groups roll up cached Thread activity and Space unread',
      (tester) async {
    final spaces = ValueNotifier<List<AxSpace>>([owned, shared]);
    addTearDown(spaces.dispose);
    final context = AxShellContext(
        navigation: const AxNavigation.home(),
        spaces: const [],
        spaceListenable: spaces,
        threadsBySpace: const {
          'owned': [thread]
        });
    await tester.pumpWidget(rail(context));
    await tester.pump();
    expect(marker('rail-activity-YOUR SPACES', 'running'), findsOneWidget);
    expect(marker('rail-activity-YOUR SPACES', 'unread'), findsNothing);
    expect(marker('rail-activity-SHARED WITH YOU', 'unread'), findsOneWidget);
    final running = marker('rail-activity-YOUR SPACES', 'running');
    expect(tester.getSize(running), const Size(9, 9));
    final fade =
        find.ancestor(of: running, matching: find.byType(FadeTransition)).first;
    expect(
        tester.widget<FadeTransition>(fade).opacity.value, closeTo(0.4, 0.001));
    await tester.pump(const Duration(milliseconds: 2800));
    expect(
        tester.widget<FadeTransition>(fade).opacity.value, closeTo(1, 0.001));
    spaces.value = [
      owned,
      AxSpace.fromJson({
        'id': 'shared',
        'name': 'Shared Space',
        'role': 'collaborator',
        'hasUnread': false
      })
    ];
    await tester.pump();
    expect(marker('rail-activity-SHARED WITH YOU', 'unread'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'collapsed switcher shows individual activity and still navigates',
      (tester) async {
    AxNavigation? destination;
    await tester.pumpWidget(rail(
        const AxShellContext(navigation: AxNavigation.home(), spaces: [
          owned,
          shared
        ], threadsBySpace: {
          'owned': [thread]
        }),
        navigate: (value) => destination = value));
    await tester.pump();
    await tester.tap(find.byTooltip('YOUR SPACES'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(marker('rail-space-activity-owned', 'running'), findsOneWidget);
    expect(marker('rail-thread-activity-thread', 'running'), findsOneWidget);
    final groupFade = tester.widget<FadeTransition>(find
        .ancestor(
            of: marker('rail-activity-YOUR SPACES', 'running'),
            matching: find.byType(FadeTransition))
        .first);
    final threadFade = tester.widget<FadeTransition>(find
        .ancestor(
            of: marker('rail-thread-activity-thread', 'running'),
            matching: find.byType(FadeTransition))
        .first);
    expect(threadFade.opacity.value, groupFade.opacity.value);
    await tester.tap(find.text('Busy Thread'));
    await tester.pump();
    expect(destination?.threadId, 'thread');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'collapsed indicators respect reduced motion and clear idle groups',
      (tester) async {
    final spaces = ValueNotifier<List<AxSpace>>([
      AxSpace.fromJson({
        'id': 'owned',
        'name': 'My Space',
        'role': 'owner',
        'hasActiveWork': true,
        'hasUnread': true
      })
    ]);
    addTearDown(spaces.dispose);
    await tester.pumpWidget(rail(
        AxShellContext(
            navigation: const AxNavigation.home(),
            spaces: const [],
            spaceListenable: spaces),
        reduceMotion: true));
    await tester.pump();
    final running = marker('rail-activity-YOUR SPACES', 'running');
    expect(running, findsOneWidget);
    expect(marker('rail-activity-YOUR SPACES', 'unread'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('rail-activity-YOUR SPACES')),
            matching: find.byType(FadeTransition)),
        findsNothing);
    expect(
        tester
            .widget<Opacity>(find
                .ancestor(of: running, matching: find.byType(Opacity))
                .first)
            .opacity,
        0.4);
    spaces.value = [owned];
    await tester.pump();
    expect(
        find.byKey(const ValueKey('sidebar-running-indicator')), findsNothing);
    expect(
        find.byKey(const ValueKey('sidebar-unread-indicator')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
