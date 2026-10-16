import 'package:conclave_design/conclave_design.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/features/navigation/space_tree.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

AxSpace _space(String id, {int? pin}) => AxSpace(
      id: id,
      name: 'Space $id',
      branch: '',
      lastActivity: '',
      role: 'owner',
      pinnedAt: pin == null ? '' : '2026-10-0${pin + 1}T00:00:00Z',
      pinPosition: pin ?? 0,
    );

AxThread _thread(String id, {int? pin}) => AxThread.fromJson({
      'id': id,
      'spaceId': 'a',
      'name': 'Thread $id',
      'pinnedAt': pin == null ? '' : '2026-10-0${pin + 1}T00:00:00Z',
      'pinPosition': pin ?? 0,
    });

Future<void> _pump(WidgetTester tester, AxNavigation navigation,
    List<AxSpace> spaces, List<AxThread> threads) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 300,
        height: 600,
        child: SingleChildScrollView(
          child: SpaceTree(
            shellContext: AxShellContext(
              navigation: navigation,
              spaces: spaces,
              threadsBySpace: {'a': threads},
              expandedSpaceIds: const {'a'},
            ),
            onNavigateTo: (_) {},
            onReorderThreads: (_, __) async {},
            onReorderPinnedSpaces: (_) async {},
            onReorderPinnedThreads: (_, __) async {},
            onSetSpacePinned: (_, __) async {},
            onSetThreadPinned: (_, __) async {},
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _open(WidgetTester tester, String tooltip) async {
  await tester.tap(find.byTooltip(tooltip));
  await tester.pumpAndSettle();
  for (final anchor in tester.widgetList<MenuAnchor>(find.byType(MenuAnchor))) {
    expect(anchor.style?.backgroundColor?.resolve({}),
        ConclaveColors.navigationBackgroundDark);
  }
}

bool _enabled(WidgetTester tester, String label) => tester
    .widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label))
    .onPressed !=
    null;

void main() {
  testWidgets('pinned Spaces get Move Up / Move Down by position',
      (tester) async {
    // "b" is first (position 0), "a" second.
    final spaces = [_space('a', pin: 1), _space('b', pin: 0)];
    await _pump(tester, const AxNavigation.space('a'), spaces, const []);
    await _open(tester, 'Space menu');
    expect(_enabled(tester, 'Move Up'), isTrue);
    expect(_enabled(tester, 'Move Down'), isFalse);
  });

  testWidgets('a single pinned Space shows both moves, disabled',
      (tester) async {
    await _pump(tester, const AxNavigation.space('a'),
        [_space('a', pin: 0), _space('b')], const []);
    await _open(tester, 'Space menu');
    expect(find.text('Move Up'), findsOneWidget);
    expect(find.text('Move Down'), findsOneWidget);
    expect(_enabled(tester, 'Move Up'), isFalse);
    expect(_enabled(tester, 'Move Down'), isFalse);
  });

  testWidgets('an unpinned Space has no move items', (tester) async {
    await _pump(tester, const AxNavigation.space('a'),
        [_space('a'), _space('b', pin: 0), _space('c', pin: 1)], const []);
    await _open(tester, 'Space menu');
    expect(find.text('Move Up'), findsNothing);
    expect(find.text('Move Down'), findsNothing);
  });

  testWidgets('only pinned Threads can move, among the pinned ones',
      (tester) async {
    final threads = [
      _thread('1', pin: 0),
      _thread('2', pin: 1),
      _thread('3'),
    ];
    final spaces = [_space('a')];
    // Middle-of-the-list pinned Thread: only Move Up (it is last of two pins).
    await _pump(tester, const AxNavigation.thread('a', '2'), spaces, threads);
    await _open(tester, 'Thread menu');
    expect(_enabled(tester, 'Move Up'), isTrue);
    expect(_enabled(tester, 'Move Down'), isFalse);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // Unpinned Thread: never.
    await _pump(tester, const AxNavigation.thread('a', '3'), spaces, threads);
    await _open(tester, 'Thread menu');
    expect(find.text('Move Up'), findsNothing);
    expect(find.text('Move Down'), findsNothing);
  });
}
