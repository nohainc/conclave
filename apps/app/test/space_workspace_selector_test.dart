import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'workflows_page_test.dart' show WorkflowSource;

const ownerSpace =
    AxSpace(id: 'S', name: 'Space', branch: '', lastActivity: 'now');
const memberSpace = AxSpace(
    id: 'S',
    name: 'Space',
    branch: '',
    lastActivity: 'now',
    role: 'collaborator');

Future<void> pumpSpace(
    WidgetTester tester, WorkflowSource source, AxSpace space) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
              child: SpacePage(
                  section: SpacePageSection.members,
                  space: space,
                  dataSource: source,
                  onOpenThread: (_) {},
                  onArchive: () {},
                  onDelete: () {})))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('owner follows the default Workspace until choosing one',
      (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    expect(find.byKey(const ValueKey('space-workspace')), findsOneWidget);
    expect(find.textContaining('Following the default Workspace: First'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Workspace').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Workspace?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-space-workspace')));
    await tester.pumpAndSettle();

    expect(source.selectedSpaceWorkspaces['S'], 'other');
    expect(find.textContaining('Following the default'), findsNothing);
    expect(find.textContaining('Workers and workflows'), findsOneWidget);
  });

  testWidgets('cancelling keeps the current Workspace', (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Second Workspace').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(source.selectedSpaceWorkspaces, isEmpty);
    expect(source.workspaceWrites, 0);
  });

  testWidgets('returning to the default Workspace inherits again',
      (tester) async {
    final source = WorkflowSource()..selectedSpaceWorkspaces['S'] = 'other';
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default Workspace').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-space-workspace')));
    await tester.pumpAndSettle();
    expect(source.selectedSpaceWorkspaces, isEmpty);
  });

  testWidgets('other members only see the Workspace', (tester) async {
    final source = WorkflowSource()..selectedSpaceWorkspaces['S'] = 'other';
    await pumpSpace(tester, source, memberSpace);
    expect(find.byKey(const ValueKey('space-workspace')), findsNothing);
    expect(find.text('Workspace: Second Workspace'), findsOneWidget);
  });
}
