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
  bool? savedAllowWork;
  bool failSave = false;
  @override
  Future<List<AxThread>> loadSpaceThreads({required String spaceId}) async =>
      [memberThread, memberThread.copyWith(name: 'Owner thread')];
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
  Future<AxSpace> updateSpace(
      {required String spaceId,
      String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) async {
    savedAllowWork = settings?['allowWork'] as bool?;
    return ownerSpace.copyWith(settings: settings);
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
    expect(find.text('Created by member@example.test'), findsNWidgets(2));
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
  });
  testWidgets(
      'Space Work switch persists and replaces technical access controls',
      (tester) async {
    final source = PermissionSource();
    await tester.pumpWidget(page(source));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Workspaces'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Edit Workspace access'), findsNothing);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(source.savedAllowWork, isFalse);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isFalse);
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
    await tester.tap(find.text('Workspaces'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Connect Workspace'), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
        isNull);
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
      'disabled Work filters composer choices and replaces a configured Work default with Chat',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = PermissionSource();
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ThreadPage(
      space: ownerSpace.copyWith(settings: {'allowWork': false}),
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
