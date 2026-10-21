import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/navigation/space_tree.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _space = AxSpace(
  id: 'space-a',
  name: 'Space A',
  branch: '',
  lastActivity: '',
  role: 'owner',
);

const _thread = AxThread(
  id: 'thread-a',
  spaceId: 'space-a',
  name: 'Thread A',
  lead: '',
  status: 'active',
  brief: '',
  primaryWorkspace: '',
  queueStatus: '',
);

void main() {
  testWidgets('archived Threads are absent from the expanded sidebar',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SpaceTree(
      shellContext: const AxShellContext(
        navigation: AxNavigation.home(),
        spaces: [_space],
        expandedSpaceIds: {'space-a'},
        threadsBySpace: {
          'space-a': [
            _thread,
            AxThread(
                id: 'archived',
                spaceId: 'space-a',
                name: 'Archived Thread',
                lead: '',
                status: 'archived',
                brief: '',
                primaryWorkspace: '',
                queueStatus: ''),
          ]
        },
      ),
      onNavigateTo: (_) {},
      onToggleSpaceExpanded: (_) {},
    ))));
    expect(find.text('Thread A'), findsOneWidget);
    expect(find.text('Archived Thread'), findsNothing);
    expect(find.textContaining('Archived ('), findsNothing);
  });

  testWidgets('hovered Space and Thread rows show their menus', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          child: SpaceTree(
            shellContext: const AxShellContext(
              navigation: AxNavigation.home(),
              spaces: [_space],
              expandedSpaceIds: {'space-a'},
              threadsBySpace: {
                'space-a': [_thread]
              },
            ),
            onNavigateTo: (_) {},
            onToggleSpaceExpanded: (_) {},
          ),
        ),
      ),
    ));
    final spaceMenu = find.byTooltip('Space menu');
    final threadMenu = find.byTooltip('Thread menu');
    expect(spaceMenu, findsNothing);
    expect(threadMenu, findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Space A')));
    await tester.pump();
    expect(spaceMenu, findsOneWidget);
    expect(threadMenu, findsNothing);

    await mouse.moveTo(tester.getCenter(find.text('Thread A')));
    await tester.pump();
    expect(spaceMenu, findsNothing);
    expect(threadMenu, findsOneWidget);

    // An open menu keeps its row active after the pointer leaves.
    await tester.tap(threadMenu);
    await tester.pumpAndSettle();
    await mouse.moveTo(const Offset(250, 590));
    await tester.pump();
    expect(threadMenu, findsOneWidget);
    expect(find.text('Rename Thread'), findsOneWidget);
  });
}
