import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/features/spaces/spaces_pages.dart';
import 'ax_fixture_data.dart';

const ownerSpace =
    AxSpace(id: 'S', name: 'Space', branch: '', lastActivity: 'now');
const memberThread = AxThread(
    id: 'T',
    spaceId: 'S',
    name: 'Member thread',
    lead: 'member',
    status: 'active',
    brief: '',
    primaryWorkspace: '',
    queueStatus: '',
    creatorEmail: 'member@example.test',
    creatorIsOwner: false,
    canExecuteWork: true);

class PermissionSource extends AxFixtureDataSource {
  AxSpacePermissions memberRights = AxSpacePermissions.forRole('collaborator');
  bool failSave = false;
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async => [
        memberThread,
        const AxThread(
            id: 'owner-thread',
            spaceId: 'S',
            name: 'Owner thread',
            lead: 'owner',
            status: 'active',
            brief: '',
            primaryWorkspace: '',
            queueStatus: '',
            creatorEmail: 'owner@example.test')
      ];
  @override
  Future<List<AxSpaceMember>> loadSpaceMembers(
          {required String spaceId}) async =>
      [
        const AxSpaceMember(
            userId: 'owner',
            displayName: 'Owner name',
            email: 'owner@example.test',
            role: 'owner',
            createdAt: 'now'),
        AxSpaceMember(
            userId: 'member',
            displayName: 'Member',
            email: 'member@example.test',
            role: 'collaborator',
            createdAt: 'now',
            permissions: memberRights),
      ];
  @override
  Future<void> updateSpaceMemberPermissions(
      {required String spaceId,
      required String userId,
      required AxSpacePermissions permissions}) async {
    if (failSave) throw Exception('Save failed');
    memberRights = permissions;
  }

  @override
  Future<List<AxBuiltinWorkflow>> loadBuiltinWorkflowCatalog() async => [
        for (final id in ['chat', 'direct'])
          AxBuiltinWorkflow(
              id: id,
              version: 1,
              name: id == 'chat' ? 'Chat workflow' : 'Work workflow',
              description: '',
              steps: const [],
              snapshot: const {},
              composerBindingId: id),
      ];
}

Widget page(PermissionSource source, {AxSpace space = ownerSpace}) =>
    MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: SpacePage(
                    space: space,
                    dataSource: source,
                    onOpenThread: (_) {},
                    onArchive: () {},
                    onDelete: () {}))));

void main() {
  testWidgets(
      'owner can change member rights in grid; owner checkboxes stay fixed; failed save preserves rights',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = PermissionSource();
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    expect(find.text('Created by member@example.test'), findsOneWidget);
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    expect(find.text('Owner'), findsOneWidget);
    expect(
        tester
            .widget<Checkbox>(
                find.byKey(const ValueKey('permission-owner-chat')))
            .onChanged,
        isNull);
    await tester.tap(find.byKey(const ValueKey('permission-member-work')));
    await tester.pumpAndSettle();
    expect(source.memberRights.work, isFalse);
    source.failSave = true;
    await tester.tap(find.byKey(const ValueKey('permission-member-chat')));
    await tester.pumpAndSettle();
    expect(source.memberRights.chat, isTrue);
    expect(
        tester
            .widget<Checkbox>(
                find.byKey(const ValueKey('permission-member-chat')))
            .value,
        isTrue);
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('member actions follow explicit rights, not collaborator role',
      (tester) async {
    final source = PermissionSource();
    final space = ownerSpace.copyWith(role: 'collaborator');
    await tester.pumpWidget(page(source,
        space: AxSpace(
            id: space.id,
            name: space.name,
            branch: '',
            lastActivity: '',
            role: 'collaborator',
            permissions:
                const AxSpacePermissions(chat: true, inviteMembers: true))));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Create Thread'), findsNothing);
    expect(find.text('Workspaces'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.text('Members'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Share Space'), findsOneWidget);
    expect(
        tester
            .widget<Checkbox>(
                find.byKey(const ValueKey('permission-member-chat')))
            .onChanged,
        isNull);
  });
  testWidgets(
      'member Work permission filters composer choices and replaces Work default with Chat',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = PermissionSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: const AxSpace(
          id: 'S',
          name: 'Space',
          branch: '',
          lastActivity: '',
          role: 'collaborator',
          permissions: AxSpacePermissions(chat: true)),
      thread:
          memberThread.copyWith(workConfig: {'defaultWorkflowId': 'direct'}),
      dataSource: source,
      initialTab: 1,
      onBackToSpace: () {},
      onArchive: () {},
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Chat workflow'), findsOneWidget);
    expect(find.text('Work workflow'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
