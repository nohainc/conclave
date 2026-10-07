import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:conclave_app/src/ax/ax_models.dart';
import 'package:conclave_app/src/ax/ax_stores.dart';
import 'package:conclave_app/src/ax/sync/ax_sync_engine.dart';
import 'ax_fixture_data.dart';

AxProject project(String id, String name) =>
    AxProject.fromJson({'id': id, 'name': name});
AxWorkstream stream(String id, String name) =>
    AxWorkstream.fromJson({'id': id, 'projectId': 'P', 'name': name});

class CollaborationSource extends AxFixtureDataSource {
  final creates = <Completer<AxProject>>[];
  final projectEdits = <Completer<AxProject>>[];
  final streamCreates = <Completer<AxWorkstream>>[];
  final streamEdits = <Completer<AxWorkstream>>[];
  final deletes = <Completer<void>>[];
  final acceptInvites = <Completer<void>>[];
  final declineInvites = <Completer<void>>[];
  @override
  Future<void> acceptProjectInvitation({required String invitationId}) {
    final response = Completer<void>();
    acceptInvites.add(response);
    return response.future;
  }

  @override
  Future<void> declineProjectInvitation({required String invitationId}) {
    final response = Completer<void>();
    declineInvites.add(response);
    return response.future;
  }
  @override
  Future<AxProject> createProject(
      {required String name, String? description, String? instructions}) {
    final response = Completer<AxProject>();
    creates.add(response);
    return response.future;
  }

  @override
  Future<AxProject> updateProject(
      {required String projectId,
      String? name,
      String? description,
      String? instructions,
      Map<String, dynamic>? settings}) {
    final response = Completer<AxProject>();
    projectEdits.add(response);
    return response.future;
  }

  @override
  Future<AxWorkstream> createWorkstream(
      {required String projectId,
      required String name,
      String? idempotencyKey}) {
    final response = Completer<AxWorkstream>();
    streamCreates.add(response);
    return response.future;
  }

  @override
  Future<AxWorkstream> updateWorkstream(
      {required String workstreamId,
      String? name,
      String? status,
      Map<String, dynamic>? workConfig}) {
    final response = Completer<AxWorkstream>();
    streamEdits.add(response);
    return response.future;
  }

  @override
  Future<void> deleteWorkstream({required String workstreamId}) {
    final response = Completer<void>();
    deletes.add(response);
    return response.future;
  }
}

void main() {
  late CollaborationSource source;
  late AxStore store;
  setUp(() {
    source = CollaborationSource();
    store = AxStore(source);
    store.projects.replace([project('P', 'Original'), project('Q', 'Other')]);
    store.syncEngine.update(
        store.projectDetails.query('P'), (_) => store.projects.items.first);
    store.syncEngine.update(store.projectWorkstreams.query('P'),
        (_) => [stream('A', 'Alpha'), stream('B', 'Beta')]);
  });

  test(
      'Project create publishes immediately, replaces temporary ID, and records details',
      () async {
    final write = store.collaboration.createProject(name: 'New');
    final temporary = store.projects.items.last;
    expect(temporary.name, 'New');
    expect(temporary.id, startsWith('local-project-'));
    source.creates.single.complete(project('new', 'Normalized'));
    expect((await write).id, 'new');
    expect(store.projects.items.map((p) => p.id), ['P', 'Q', 'new']);
    expect(store.projectDetails.peek('new')?.name, 'Normalized');
  });

  test('one failed Project create cannot remove another confirmed create',
      () async {
    final first = store.collaboration.createProject(name: 'Failed');
    final check = expectLater(first, throwsStateError);
    final second = store.collaboration.createProject(name: 'Saved');
    source.creates[1].complete(project('new', 'Saved'));
    await second;
    source.creates[0].completeError(StateError('denied'));
    await check;
    expect(store.projects.items.map((p) => p.name),
        ['Original', 'Other', 'Saved']);
  });

  test(
      'Project edit updates list and detail optimistically and reconciles server fields',
      () async {
    final write = store.collaboration.editProject(store.projects.items.first,
        name: 'Optimistic', instructions: 'New instructions');
    expect(store.projects.items.first.name, 'Optimistic');
    expect(store.projectDetails.peek('P')?.instructions, 'New instructions');
    source.projectEdits.single.complete(project('P', 'Normalized')
        .copyWith(instructions: 'Normalized instructions'));
    await write;
    expect(store.projects.items.first.name, 'Normalized');
    expect(store.projectDetails.peek('P')?.instructions,
        'Normalized instructions');
  });

  test(
      'failed Project edit restores latest realtime base and preserves other Project edits',
      () async {
    final original = store.projects.items.first;
    final write = store.collaboration.editProject(original, name: 'Pending');
    final check = expectLater(write, throwsStateError);
    final latest =
        original.copyWith(name: 'Remote', description: 'Remote description');
    store.syncEngine.update(store.projectDetails.query('P'), (_) => latest);
    store.projects.replace([latest, project('Q', 'Remote Q')]);
    expect(store.projectDetails.peek('P')?.name, 'Pending');
    expect(store.projectDetails.peek('P')?.description, 'Remote description');
    expect(store.projects.items.first.description, 'Remote description');
    source.projectEdits.single.completeError(StateError('denied'));
    await check;
    expect(store.projectDetails.peek('P')?.name, 'Remote');
    expect(store.projects.items.map((p) => p.name), ['Remote', 'Remote Q']);
  });

  test('second write to the same Project is rejected before issuing HTTP',
      () async {
    final original = store.projects.items.first;
    final first = store.collaboration.editProject(original, name: 'First');
    await expectLater(
        store.collaboration.editProject(original, name: 'Duplicate'),
        throwsStateError);
    expect(source.projectEdits.length, 1);
    source.projectEdits.single.complete(original.copyWith(name: 'First'));
    await first;
  });

  test(
      'Workstream create failure retains another create and collection ordering',
      () async {
    final first =
        store.collaboration.createWorkstream(projectId: 'P', name: 'Failed');
    final check = expectLater(first, throwsStateError);
    final second =
        store.collaboration.createWorkstream(projectId: 'P', name: 'Saved');
    expect(store.projectWorkstreams.peek('P').map((w) => w.name),
        ['Alpha', 'Beta', 'Failed', 'Saved']);
    source.streamCreates[1].complete(stream('C', 'Saved'));
    await second;
    source.streamCreates[0].completeError(StateError('denied'));
    await check;
    expect(
        store.projectWorkstreams.peek('P').map((w) => w.id), ['A', 'B', 'C']);
  });

  test('Workstream edits preserve position and unrelated realtime entities',
      () async {
    final original = store.projectWorkstreams.peek('P').first;
    final write = store.collaboration.editWorkstream(original, name: 'Pending');
    store.syncEngine.update(
        store.projectWorkstreams.query('P'),
        (_) => [
              original,
              stream('B', 'Remote Beta'),
              stream('C', 'Remote Gamma')
            ]);
    expect(store.projectWorkstreams.peek('P').map((w) => w.name),
        ['Pending', 'Remote Beta', 'Remote Gamma']);
    source.streamEdits.single.complete(original.copyWith(name: 'Normalized'));
    await write;
    expect(store.projectWorkstreams.peek('P').map((w) => w.name),
        ['Normalized', 'Remote Beta', 'Remote Gamma']);
  });

  test(
      'failed Workstream delete restores only the removed entity from latest base',
      () async {
    final original = store.projectWorkstreams.peek('P').first;
    final write = store.collaboration.deleteWorkstream(original);
    final check = expectLater(write, throwsStateError);
    expect(store.projectWorkstreams.peek('P').map((w) => w.id), ['B']);
    store.syncEngine.update(store.projectWorkstreams.query('P'),
        (_) => [original, stream('B', 'Remote Beta')]);
    source.deletes.single.completeError(StateError('denied'));
    await check;
    expect(store.projectWorkstreams.peek('P').map((w) => w.name),
        ['Alpha', 'Remote Beta']);
  });

  test('confirmed Workstream delete removes its dependent queries', () async {
    final key = AxQueryKey(['workstream', 'A', 'discussion']);
    final dependent = AxQuery<int>(key: key, load: () async => 1);
    store.syncEngine.update(dependent, (_) => 1);
    final write = store.collaboration
        .deleteWorkstream(store.projectWorkstreams.peek('P').first);
    source.deletes.single.complete();
    await write;
    expect(store.syncEngine.peek(dependent).hasData, isFalse);
    expect(store.projectWorkstreams.peek('P').map((w) => w.id), ['B']);
  });

  test(
      'wrong response identity rolls back rather than corrupting another Project',
      () async {
    final write = store.collaboration.editWorkstream(
        store.projectWorkstreams.peek('P').first,
        name: 'Pending');
    final check = expectLater(write, throwsA(isA<Exception>()));
    source.streamEdits.single.complete(
        AxWorkstream.fromJson({'id': 'A', 'projectId': 'Q', 'name': 'Wrong'}));
    await check;
    expect(store.projectWorkstreams.peek('P').first.name, 'Alpha');
  });

  test(
      'session clear fences Project and Workstream writes and releases temporary rows',
      () async {
    final projectWrite = store.collaboration.createProject(name: 'Pending');
    final streamWrite =
        store.collaboration.createWorkstream(projectId: 'P', name: 'Pending');
    final checks = Future.wait([
      expectLater(projectWrite, throwsA(isA<AxMutationSuperseded>())),
      expectLater(streamWrite, throwsA(isA<AxMutationSuperseded>())),
    ]);
    store.clearServerState();
    source.creates.single.complete(project('late', 'Late'));
    source.streamCreates.single.complete(stream('late', 'Late'));
    await checks;
    expect(store.projects.items, isEmpty);
    expect(store.projectWorkstreams.peek('P'), isEmpty);
    expect(store.projectDetails.peek('late'), isNull);
  });

  test(
      'Project removal cancels the remaining list overlay without resurrecting a deleted Project',
      () async {
    final write = store.collaboration
        .editProject(store.projects.items.first, name: 'Pending');
    final check = expectLater(write, throwsA(isA<AxMutationSuperseded>()));
    store.syncEngine.remove(store.projectDetails.query('P').key);
    store.projects.replace([project('Q', 'Other')]);
    expect(store.projects.items.map((p) => p.id), ['Q']);
    source.projectEdits.single.complete(project('P', 'Late'));
    await check;
    expect(store.projects.items.map((p) => p.id), ['Q']);
  });

  test(
      'acceptInvitation removes invitation immediately, adds project optimistically, and confirms on server completion',
      () async {
    final invite = AxProjectInvitation(
      id: 'inv-1',
      projectId: 'proj-new',
      projectName: 'Alpha Project',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);
    expect(store.invitations.items.map((i) => i.id), ['inv-1']);
    expect(store.projects.items.map((p) => p.id), ['P', 'Q']);

    final write = store.collaboration.acceptInvitation(invite);

    // Optimistic state
    expect(store.invitations.items, isEmpty);
    expect(store.projects.items.map((p) => p.id), ['P', 'Q', 'proj-new']);
    expect(store.projects.items.last.name, 'Alpha Project');

    // Complete server write
    source.acceptInvites.single.complete();
    await write;

    expect(store.invitations.items, isEmpty);
    expect(store.projects.items.map((p) => p.id), ['P', 'Q', 'proj-new']);
  });

  test(
      'failed acceptInvitation rolls back removed invitation and optimistic project',
      () async {
    final invite = AxProjectInvitation(
      id: 'inv-1',
      projectId: 'proj-new',
      projectName: 'Alpha Project',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);

    final write = store.collaboration.acceptInvitation(invite);
    final check = expectLater(write, throwsA(isA<StateError>()));

    expect(store.invitations.items, isEmpty);
    expect(store.projects.items.map((p) => p.id), ['P', 'Q', 'proj-new']);

    source.acceptInvites.single.completeError(StateError('expired'));
    await check;

    // Rolled back
    expect(store.invitations.items.map((i) => i.id), ['inv-1']);
    expect(store.projects.items.map((p) => p.id), ['P', 'Q']);
  });

  test(
      'declineInvitation removes invitation immediately and confirms on server completion',
      () async {
    final invite = AxProjectInvitation(
      id: 'inv-1',
      projectId: 'proj-new',
      projectName: 'Alpha Project',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);

    final write = store.collaboration.declineInvitation(invite);
    expect(store.invitations.items, isEmpty);

    source.declineInvites.single.complete();
    await write;

    expect(store.invitations.items, isEmpty);
  });

  test('failed declineInvitation rolls back removed invitation', () async {
    final invite = AxProjectInvitation(
      id: 'inv-1',
      projectId: 'proj-new',
      projectName: 'Alpha Project',
      email: 'user@example.com',
      role: 'member',
      status: 'pending',
      invitedByUserId: 'u-1',
      createdAt: DateTime.now().toIso8601String(),
    );
    store.invitations.replace([invite]);

    final write = store.collaboration.declineInvitation(invite);
    final check = expectLater(write, throwsA(isA<StateError>()));

    expect(store.invitations.items, isEmpty);

    source.declineInvites.single.completeError(StateError('forbidden'));
    await check;

    expect(store.invitations.items.map((i) => i.id), ['inv-1']);
  });
}
