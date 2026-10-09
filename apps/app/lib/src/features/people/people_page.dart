import 'dart:async';
import 'package:flutter/material.dart';
import '../../ax/ax_people.dart';
import '../../ax/sync/ax_people.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';
import '../invitations/space_invitation_dialog.dart';

class PeoplePage extends StatefulWidget {
  const PeoplePage({super.key, required this.people});
  final AxPeople people;
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  String _search = '';
  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(PeoplePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.people != widget.people) {
      _search = '';
      _ensure();
    }
  }

  void _ensure() => unawaited(widget.people
      .ensure()
      .then<void>((_) {}, onError: (Object _, StackTrace __) {}));

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
      engine: widget.people.engine,
      query: widget.people.query,
      ensure: false,
      builder: (context, state) {
        final people = state.data ?? const <AxPerson>[];
        final filtered = people.where((p) =>
            p.displayName.toLowerCase().contains(_search) ||
            p.email.toLowerCase().contains(_search));
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('People', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          const Text('People you collaborate with in Conclave.'),
          const SizedBox(height: 20),
          TextField(
              key: const ValueKey('people-search'),
              decoration: const InputDecoration(
                  hintText: 'Search people...', prefixIcon: Icon(Icons.search)),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase())),
          const SizedBox(height: 16),
          _PeopleReadStatus(people: widget.people, state: state),
          if (state.hasData && people.isEmpty)
            const Text(
                'People you collaborate with will appear here\nafter they accept a Space invitation.'),
          if (people.isNotEmpty && filtered.isEmpty)
            const Text('No people match your search.'),
          for (final person in filtered)
            Card(
                child: ListTile(
              key: ValueKey('person-${person.userId}'),
              leading: const CircleAvatar(child: Icon(Icons.person_outline)),
              title: Text(person.displayName),
              subtitle: Text(
                  '${person.sharedSpaceCount} shared ${person.sharedSpaceCount == 1 ? 'Space' : 'Spaces'}${person.sharedSpaces.isEmpty ? '' : '\n${person.sharedSpaces.map((s) => s.name).join(', ')}'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
              isThreeLine: person.sharedSpaces.isNotEmpty,
              onTap: () => _view(person.userId),
              trailing: TextButton(
                  onPressed: () => _view(person.userId),
                  child: const Text('View')),
            )),
        ]);
      });

  Future<void> _view(String userId) => showDialog<void>(
      context: context,
      builder: (_) => _PersonDetails(people: widget.people, userId: userId));
}

class _PeopleReadStatus extends StatelessWidget {
  const _PeopleReadStatus({required this.people, required this.state});
  final AxPeople people;
  final AxQueryState<List<AxPerson>> state;
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (state.isFetching)
          const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator()),
        if (state.error != null)
          Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(children: [
                Expanded(
                    child: Text(state.hasData
                        ? 'People could not be updated. Check your connection. Cached details remain available.'
                        : 'People could not be loaded. Check your connection.')),
                TextButton(
                    onPressed: () => unawaited(people.refresh().then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {})),
                    child: const Text('Retry')),
              ])),
      ]);
}

AxPerson? _person(List<AxPerson>? people, String id) {
  for (final person in people ?? const <AxPerson>[]) {
    if (person.userId == id) return person;
  }
  return null;
}

class _PersonDetails extends StatefulWidget {
  const _PersonDetails({required this.people, required this.userId});
  final AxPeople people;
  final String userId;
  @override
  State<_PersonDetails> createState() => _PersonDetailsState();
}

class _PersonDetailsState extends State<_PersonDetails> {
  bool _invited = false;
  AxPeople get people => widget.people;
  String get userId => widget.userId;
  Future<void> _add() async {
    final sent = await showDialog<bool>(
        context: context,
        builder: (_) =>
            SpaceInvitationDialog(people: people, personId: userId));
    if (mounted && sent == true) setState(() => _invited = true);
  }

  @override
  Widget build(BuildContext context) => AxQueryBuilder(
      engine: people.engine,
      query: people.query,
      ensure: false,
      builder: (context, state) {
        final person = _person(state.data, userId);
        return AlertDialog(
          title: Text(person?.displayName ?? 'Person unavailable'),
          content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                  child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    _PeopleReadStatus(people: people, state: state),
                    if (person != null) ...[
                      Text(person.email),
                      if (_invited)
                        const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: Text(
                                'Invitation sent. Waiting for acceptance.')),
                      const SizedBox(height: 20),
                      Text('Shared Spaces',
                          style: Theme.of(context).textTheme.titleMedium),
                      const Divider(),
                      if (person.sharedSpaces.isEmpty)
                        const Text('No shared Spaces.'),
                      for (final space in person.sharedSpaces)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.group_work_outlined),
                            title: Text(space.name)),
                      const SizedBox(height: 16),
                      if (person.invitableSpaces.isEmpty)
                        const Text(
                            'No Spaces available to invite this person to.'),
                    ] else
                      const Text(
                          'This person is no longer available in your People directory.'),
                  ]))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Close')),
            FilledButton(
                onPressed: person != null &&
                        person.invitableSpaces.isNotEmpty &&
                        state.error == null &&
                        !state.isFetching
                    ? _add
                    : null,
                child: const Text('Add to Space')),
          ],
        );
      });
}
