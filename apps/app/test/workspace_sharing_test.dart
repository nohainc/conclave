import 'package:conclave_app/src/ax/ax_workspace_member_access.dart';
import 'package:conclave_app/src/features/workspace/workspace_sharing_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class SharingSource implements AxWorkspaceSharingDataSource {
  List<AxPersonWithAccess> people = const [
    AxPersonWithAccess(
        userId: 'guest',
        displayName: 'Guest',
        email: 'guest@test',
        status: 'active',
        custom: true,
        mode: 'chat',
        usage: AxPersonUsage(
            requests: 2, approxSeconds: 90, workerIds: ['worker-a'])),
  ];
  List<AxSharedWorkspaceInvitation> invitations = const [
    AxSharedWorkspaceInvitation(
        id: 'i1', email: 'new@test', status: 'pending', expiresAt: 'later'),
  ];
  List<AxMyWorkspaceInvitation> mine = const [
    AxMyWorkspaceInvitation(
        id: 'm1', workspaceName: 'Mac', ownerName: 'Lender', expiresAt: 'later'),
  ];
  final calls = <String>[];

  @override
  Future<List<AxPersonWithAccess>> loadPeopleWithAccess(String w) async =>
      people;
  @override
  Future<List<AxSharedWorkspaceInvitation>> loadSharedWorkspaceInvitations(
          String w) async =>
      invitations;
  @override
  Future<void> createWorkspaceInvitation(String w, String email) async =>
      calls.add('invite:$email');
  @override
  Future<void> revokeWorkspaceInvitation(String w, String id) async =>
      calls.add('cancel:$id');
  @override
  Future<void> revokePersonGrant(String w, String userId) async =>
      calls.add('revoke:$userId');
  @override
  Future<void> setPersonQuota(String w, String userId, int limit) async =>
      calls.add('quota:$userId:$limit');
  @override
  Future<List<AxMyWorkspaceInvitation>> loadMyWorkspaceInvitations() async =>
      mine;
  @override
  Future<void> acceptWorkspaceInvitation(String id) async {
    calls.add('accept:$id');
    mine = const [];
  }
}

Future<void> pump(WidgetTester tester, Widget child) async {
  await tester.binding.setSurfaceSize(const Size(900, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))));
  await tester.pumpAndSettle();
}

void main() {
  test('people with access parse usage and ignore unknown modes', () {
    final person = AxPersonWithAccess.fromJson({
      'userId': 'u',
      'displayName': 'U',
      'email': 'u@test',
      'status': 'active',
      'custom': true,
      'mode': 'root',
      'maxConcurrentRequests': 3,
      'usage': {
        'requests': 4,
        'approxSeconds': 120,
        'lastUsedAt': 'then',
        'workerIds': ['w']
      }
    });
    expect(person.mode, isNull);
    expect(person.maxConcurrentRequests, 3);
    expect(person.usage.requests, 4);
    expect(person.usage.workerIds, ['w']);
    expect(person.active, isTrue);
  });

  testWidgets('owner invites, cancels, sets the quota and revokes',
      (tester) async {
    final source = SharingSource();
    await pump(tester,
        WorkspaceSharingSection(workspaceId: 'ws', source: source));
    expect(find.textContaining('Guest · guest@test'), findsOneWidget);
    expect(find.textContaining('2 requests'), findsOneWidget);
    expect(find.textContaining('Chat only (custom)'), findsOneWidget);
    await tester.enterText(
        find.byKey(const ValueKey('sharing-invite-email')), 'a@b.test');
    await tester.tap(find.byKey(const ValueKey('sharing-invite')));
    await tester.pumpAndSettle();
    await tester.tap(
        find.byKey(const ValueKey('sharing-revoke-invitation-i1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-revoke-guest')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sharing-confirm-revoke')));
    await tester.pumpAndSettle();
    expect(source.calls, ['invite:a@b.test', 'cancel:i1', 'revoke:guest']);
  });

  testWidgets('an invited person accepts and the banner clears',
      (tester) async {
    final source = SharingSource();
    var accepted = 0;
    await pump(tester,
        WorkspaceInvitationsBanner(source: source, onAccepted: () => accepted++));
    expect(find.textContaining('Lender invited you to use Mac'), findsOneWidget);
    await tester
        .tap(find.byKey(const ValueKey('accept-workspace-invitation-m1')));
    await tester.pumpAndSettle();
    expect(source.calls, ['accept:m1']);
    expect(accepted, 1);
    expect(find.textContaining('invited you'), findsNothing);
  });
}
