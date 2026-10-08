import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/ax_sidebar.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';

const own = AxSpace(
    id: 'own',
    name: 'Owned space',
    branch: '',
    lastActivity: '',
    role: 'owner');
const shared = AxSpace(
    id: 'shared',
    name: 'Shared space',
    branch: '',
    lastActivity: '',
    role: 'collaborator');

void main() {
  for (final spaces in [
    <AxSpace>[],
    [own],
    [shared],
    [shared, own]
  ]) {
    final context =
        AxShellContext(navigation: const AxNavigation.home(), spaces: spaces);
    testWidgets('expanded space groups: ${spaces.map((p) => p.id)}',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: SpaceTree(
        shellContext: context,
        onNavigateTo: (_) {},
        onToggleSpaceExpanded: (_) {},
        onCreateSpace: () {},
      ))));
      expect(
          find.text('YOUR SPACES'),
          spaces.contains(own) && spaces.contains(shared)
              ? findsOneWidget
              : findsNothing);
      expect(find.text('SHARED WITH YOU'),
          spaces.contains(shared) ? findsOneWidget : findsNothing);
      if (spaces.length == 2) {
        expect(tester.getTopLeft(find.text(own.name)).dy,
            lessThan(tester.getTopLeft(find.text(shared.name)).dy));
      }
    });
    testWidgets('collapsed space selectors: ${spaces.map((p) => p.id)}',
        (tester) async {
      AxNavigation? selected;
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: AxIconRail(
        shellContext: context,
        onNavigateTo: (nav) => selected = nav,
        onOpenDrawer: () {},
        onLogout: () {},
        onOpenAbout: () {},
        onOpenExternal: (_) {},
      ))));
      expect(find.byTooltip('YOUR SPACES'),
          spaces.contains(own) ? findsOneWidget : findsNothing);
      expect(find.byTooltip('SHARED WITH YOU'),
          spaces.contains(shared) ? findsOneWidget : findsNothing);
      if (spaces.contains(shared)) {
        await tester.tap(find.byTooltip('SHARED WITH YOU'));
        await tester.pumpAndSettle();
        expect(find.text(own.name), findsNothing);
        await tester.tap(find.text(shared.name));
        await tester.pumpAndSettle();
        expect(selected?.spaceId, shared.id);
      }
    });
  }
}
