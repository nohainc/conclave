import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/navigation/ax_sidebar.dart';
import 'package:conclave_app/src/features/navigation/ax_shell_context.dart';
import 'package:conclave_app/src/navigation/ax_navigation.dart';

const own = AxProject(
    id: 'own',
    name: 'Owned project',
    branch: '',
    lastActivity: '',
    role: 'owner');
const shared = AxProject(
    id: 'shared',
    name: 'Shared project',
    branch: '',
    lastActivity: '',
    role: 'collaborator');

void main() {
  for (final projects in [
    <AxProject>[],
    [own],
    [shared],
    [shared, own]
  ]) {
    final context = AxShellContext(
        navigation: const AxNavigation.home(), projects: projects);
    testWidgets('expanded project groups: ${projects.map((p) => p.id)}',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ProjectTree(
        shellContext: context,
        onNavigateTo: (_) {},
        onToggleProjectExpanded: (_) {},
        onCreateProject: () {},
      ))));
      expect(
          find.text('Your projects'),
          projects.contains(own) && projects.contains(shared)
              ? findsOneWidget
              : findsNothing);
      expect(find.text('Shared with you'),
          projects.contains(shared) ? findsOneWidget : findsNothing);
      if (projects.length == 2) {
        expect(tester.getTopLeft(find.text(own.name)).dy,
            lessThan(tester.getTopLeft(find.text(shared.name)).dy));
      }
    });
    testWidgets('collapsed project selectors: ${projects.map((p) => p.id)}',
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
      expect(find.byTooltip('Your projects'),
          projects.contains(own) ? findsOneWidget : findsNothing);
      expect(find.byTooltip('Shared with you'),
          projects.contains(shared) ? findsOneWidget : findsNothing);
      if (projects.contains(shared)) {
        await tester.tap(find.byTooltip('Shared with you'));
        await tester.pumpAndSettle();
        expect(find.text(own.name), findsNothing);
        await tester.tap(find.text(shared.name));
        await tester.pumpAndSettle();
        expect(selected?.projectId, shared.id);
      }
    });
  }
}
