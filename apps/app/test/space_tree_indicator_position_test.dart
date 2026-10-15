import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/navigation/space_tree.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

const _space = AxSpace(
  id: 'space-a',
  name: 'Space A',
  branch: '',
  lastActivity: '',
  role: 'owner',
  hasActiveWork: true,
  hasUnread: true,
);

Future<double> _runningIndicatorRight(
  WidgetTester tester,
  AxNavigation navigation,
) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 260,
        child: SpaceTree(
          shellContext: AxShellContext(
            navigation: navigation,
            spaces: const [_space],
          ),
          onNavigateTo: (_) {},
          onToggleSpaceExpanded: (_) {},
        ),
      ),
    ),
  ));
  // The running indicator pulses forever, so settle is not possible.
  await tester.pump();
  return tester
      .getTopRight(find.byKey(const ValueKey('sidebar-running-indicator')))
      .dx;
}

void main() {
  testWidgets('Space and Thread rows are 30 px in every selection state',
      (tester) async {
    const threads = [
      AxThread(
          id: 'active',
          spaceId: 'space-a',
          name: 'Active Thread',
          lead: '',
          status: 'active',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
      AxThread(
          id: 'archived',
          spaceId: 'space-a',
          name: 'Archived Thread',
          lead: '',
          status: 'archived',
          brief: '',
          primaryWorkspace: '',
          queueStatus: ''),
    ];
    for (final navigation in [
      const AxNavigation.home(),
      const AxNavigation.space('space-a'),
      const AxNavigation.thread('space-a', 'active'),
      const AxNavigation.thread('space-a', 'archived'),
    ]) {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SizedBox(
        width: 260,
        child: SpaceTree(
          shellContext: AxShellContext(
            navigation: navigation,
            spaces: const [_space],
            expandedSpaceIds: const {'space-a'},
            threadsBySpace: const {'space-a': threads},
          ),
          onNavigateTo: (_) {},
          onToggleSpaceExpanded: (_) {},
        ),
      ))));
      await tester.pump();
      for (final label in ['Space A', 'Active Thread', 'Archived Thread']) {
        final row = find
            .ancestor(of: find.text(label), matching: find.byType(InkWell))
            .first;
        expect(tester.getSize(row).height, 30, reason: '$label at $navigation');
      }
      if (navigation.kind == AxRouteKind.space || navigation.threadId != null) {
        final menu = find.byTooltip(
            navigation.threadId == null ? 'Space menu' : 'Thread menu');
        expect(menu, findsOneWidget);
        await tester.tap(menu);
        await tester.pump();
        expect(
            find.text(
                navigation.threadId == null ? 'Edit Space' : 'Rename Thread'),
            findsOneWidget);
        await tester.tapAt(const Offset(500, 500));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('activity indicators stay put when the Space is selected',
      (tester) async {
    final unselected =
        await _runningIndicatorRight(tester, const AxNavigation.home());
    final selected = await _runningIndicatorRight(
        tester, const AxNavigation.space('space-a'));

    expect(selected, unselected);
  });

  testWidgets('selected Space keeps the same row typography and height',
      (tester) async {
    Future<({double height, Color? color, FontWeight? weight})> render(
        AxNavigation navigation) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            child: SpaceTree(
              shellContext: AxShellContext(
                navigation: navigation,
                spaces: const [_space],
              ),
              onNavigateTo: (_) {},
              onToggleSpaceExpanded: (_) {},
            ),
          ),
        ),
      ));
      await tester.pump();
      final text = tester.widget<Text>(find.text('Space A'));
      final paragraph =
          tester.renderObject<RenderParagraph>(find.text('Space A'));
      return (
        height: tester.getSize(find.text('Space A')).height,
        color: paragraph.text.style?.color,
        weight: text.style?.fontWeight,
      );
    }

    final unselected = await render(const AxNavigation.home());
    final selected = await render(const AxNavigation.space('space-a'));
    expect(selected.height, unselected.height);
    expect(selected.color, unselected.color);
    expect(selected.weight, unselected.weight);
  });
}
