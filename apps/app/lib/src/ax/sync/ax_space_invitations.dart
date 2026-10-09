import '../ax_data.dart';
import '../ax_models.dart';
import 'ax_people.dart';
import 'ax_sync_engine.dart';

/// Both invitation entry points use this writer; membership requires acceptance.
class AxSpaceInvitations {
  AxSpaceInvitations(this.people);
  final AxPeople people;
  Future<void> send(
      {required AxPeopleSpace space,
      required AxSpacePermissions permissions,
      String? userId,
      String? email}) async {
    if ((userId == null) == (email == null)) {
      throw ArgumentError('Select a Person or provide an email');
    }
    if (!space.canInvite) {
      throw StateError('Only the Space owner can invite members');
    }
    final engine = people.engine;
    final current = engine.fence(AxPeople.key);
    if (!current()) throw const AxMutationSuperseded();
    final allowed = space.permissions.toJson();
    final selected = permissions.toJson();
    if (selected.entries
        .any((entry) => entry.value && allowed[entry.key] != true)) {
      throw StateError('Permission is not available');
    }
    final role =
        selected.values.any((value) => value) ? 'collaborator' : 'viewer';
    try {
      if (userId != null) {
        await (people.source as AxPeopleDataSource).invitePersonToSpace(
            spaceId: space.id,
            userId: userId,
            role: role,
            permissions: permissions);
      } else {
        await people.source.inviteSpaceMemberWithPermissions(
            spaceId: space.id,
            email: email!.trim(),
            role: role,
            permissions: permissions);
      }
    } catch (_) {
      if (!current()) throw const AxMutationSuperseded();
      rethrow;
    }
    if (!current()) throw const AxMutationSuperseded();
    await Future.wait([
      people
          .refresh()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
      engine
          .revalidateWhere((key) =>
              key.parts.length == 3 &&
              key.parts[0] == 'space' &&
              key.parts[1] == space.id &&
              const {'invitations', 'audit'}.contains(key.parts[2]))
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    ]);
  }
}
