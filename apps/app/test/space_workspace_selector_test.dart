import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'package:conclave_app/src/ax/sync/ax_discussion_cache.dart';
import 'package:conclave_app/src/ax/sync/ax_work_history.dart';
import 'package:conclave_app/src/ax/sync/persistence/ax_thread_view_state_store.dart';
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
          body: NewThreadPage(
    space: space,
    dataSource: source,
    discussionCache: AxDiscussionCache.forSource(source),
    workHistoryCache: AxWorkHistoryCache.forSource(source),
    threadViewStateStore: MemoryAxThreadViewStateStore(),
    createThread: (_) async => throw StateError('Not used'),
    onOpenThread: (_) {},
  ))));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('owner follows the default Workspace until choosing one',
      (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    expect(find.byKey(const ValueKey('space-workspace')), findsOneWidget);
    final selector = find.byKey(const ValueKey('space-workspace'));
    final name = find.byKey(const ValueKey('new-thread-name'));
    expect(tester.getRect(selector).width, tester.getRect(name).width);
    expect(tester.getRect(selector).bottom, lessThan(tester.getRect(name).top));
    expect(
        tester.getRect(selector).bottom,
        lessThan(tester
            .getRect(find.text('Choose what each member can do in this Space.'))
            .top));

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
    expect(find.textContaining('Threads use this Workspace'), findsNothing);
  });

  testWidgets('equivalent explicit and default choices save without a warning',
      (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('First Workspace').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Workspace?'), findsNothing);
    expect(source.selectedSpaceWorkspaces['S'], 'ws');
    expect(source.workspaceWrites, 1);
    await tester.tap(find.byKey(const ValueKey('space-workspace')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Default Workspace').last);
    await tester.pumpAndSettle();
    expect(find.text('Change Workspace?'), findsNothing);
    expect(source.selectedSpaceWorkspaces, isEmpty);
    expect(source.workspaceWrites, 2);
  });

  testWidgets('narrow Space keeps Workspace above Thread name', (tester) async {
    final source = WorkflowSource();
    await pumpSpace(tester, source, ownerSpace);
    await tester.binding.setSurfaceSize(const Size(600, 1000));
    await tester.pumpAndSettle();
    expect(
        tester.getRect(find.byKey(const ValueKey('space-workspace'))).bottom,
        lessThan(
            tester.getRect(find.byKey(const ValueKey('new-thread-name'))).top));
    expect(tester.takeException(), isNull);
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
