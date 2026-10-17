import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/ax_workspace_member_access.dart';
import 'workspace_member_access_section.dart';
import '../common/quiet_notices.dart';

/// Monthly run-time limits offered to the owner, in hours (null = no limit).
const _runTimeHours = <int?>[null, 1, 5, 10, 25, 50, 100];

const _modeLabels = {
  'chat': 'Chat only',
  'work': 'Chat and work',
  'work+shell': 'Work and commands',
};

String _duration(int seconds) {
  if (seconds < 60) return '${seconds}s';
  if (seconds < 3600) return '${seconds ~/ 60}m';
  return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
}

/// Owner control for lending a Workspace to people (ADR-020): invite by email,
/// see who has access with usage only (never their content), set how many
/// requests they may run at once, and revoke.
class WorkspaceSharingSection extends StatefulWidget {
  const WorkspaceSharingSection({
    super.key,
    required this.workspaceId,
    required this.source,
    this.memberAccessSource,
    this.personAccessSource,
    this.workers = const [],
  });

  final String workspaceId;
  final AxWorkspaceSharingDataSource source;

  /// Enable "Edit access" for each person: which Workers, models, efforts and
  /// mode they get. Both sources are needed, plus the Workspace's Workers.
  final AxWorkspaceMemberAccessDataSource? memberAccessSource;
  final AxWorkspacePersonAccessDataSource? personAccessSource;
  final List<AxWorker> workers;

  @override
  State<WorkspaceSharingSection> createState() =>
      _WorkspaceSharingSectionState();
}

class _WorkspaceSharingSectionState extends State<WorkspaceSharingSection> {
  final _email = TextEditingController();
  bool _loading = true;
  bool _busy = false;
  Object? _error;
  List<AxPersonWithAccess> _people = const [];
  List<AxSharedWorkspaceInvitation> _invitations = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(WorkspaceSharingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspaceId != widget.workspaceId) unawaited(_load());
  }

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final workspaceId = widget.workspaceId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final people = await widget.source.loadPeopleWithAccess(workspaceId);
      final invitations =
          await widget.source.loadSharedWorkspaceInvitations(workspaceId);
      if (!mounted || workspaceId != widget.workspaceId) return;
      setState(() {
        _people = people;
        _invitations = invitations;
      });
    } catch (error) {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _error = error);
      }
    } finally {
      if (mounted && workspaceId == widget.workspaceId) {
        setState(() => _loading = false);
      }
    }
  }

  /// Run a change, report failures, then refresh the lists.
  Future<void> _act(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  Future<void> _invite() async {
    final email = _email.text.trim();
    if (!email.contains('@')) return;
    await _act(() async {
      await widget.source.createWorkspaceInvitation(widget.workspaceId, email);
      _email.clear();
    });
  }

  Future<void> _editAccess(AxPersonWithAccess person) async {
    await showDialog<void>(
        context: context,
        builder: (context) => Dialog(
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: WorkspaceMemberAccessSection(
                        key: ValueKey('person-access-${person.userId}'),
                        workspaceId: widget.workspaceId,
                        workers: widget.workers,
                        source: widget.memberAccessSource!,
                        personSource: widget.personAccessSource,
                        userId: person.userId,
                        personName: person.displayName)))));
    if (mounted) await _load();
  }

  Future<void> _revokePerson(AxPersonWithAccess person) async {
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text('Revoke access for ${person.displayName}?'),
              content: const Text(
                  'They stop being able to run on this Workspace. Work already running finishes.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    key: const ValueKey('sharing-confirm-revoke'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Revoke')),
              ],
            ));
    if (confirmed != true) return;
    await _act(() =>
        widget.source.revokePersonGrant(widget.workspaceId, person.userId));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Lend this Workspace',
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text(
            'Invite someone by email. They use this Workspace from their own Spaces; you see usage only, never their Threads or prompts.',
            style: muted),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
              child: TextField(
                  key: const ValueKey('sharing-invite-email'),
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                      labelText: 'Email', border: OutlineInputBorder()),
                  onSubmitted: (_) => _busy ? null : _invite())),
          const SizedBox(width: 8),
          FilledButton(
              key: const ValueKey('sharing-invite'),
              onPressed: _busy ? null : _invite,
              child: const Text('Invite')),
        ]),
        const SizedBox(height: 8),
        if (_loading)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()))
        else if (_error != null)
          Row(children: [
            const Expanded(child: Text('Sharing could not be loaded.')),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ])
        else ...[
          for (final invitation
              in _invitations.where((item) => item.status == 'pending'))
            ListTile(
                key: ValueKey('sharing-invitation-${invitation.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(invitation.email),
                subtitle: const Text('Invitation pending'),
                trailing: TextButton(
                    key: ValueKey('sharing-revoke-invitation-${invitation.id}'),
                    onPressed: _busy
                        ? null
                        : () => _act(() => widget.source
                            .revokeWorkspaceInvitation(
                                widget.workspaceId, invitation.id)),
                    child: const Text('Cancel invitation'))),
          if (_people.isEmpty)
            Text('No one has access yet.', style: muted)
          else
            for (final person in _people) _personTile(person, muted),
        ],
      ],
    );
  }

  int? _hours(AxPersonWithAccess person) => person.maxRunSecondsPerMonth == null
      ? null
      : person.maxRunSecondsPerMonth! ~/ 3600;

  Widget _personTile(AxPersonWithAccess person, TextStyle muted) {
    final mode =
        person.mode == null ? 'Default access' : _modeLabels[person.mode]!;
    final usage = person.usage;
    return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text('${person.displayName} · ${person.email}',
                    style: const TextStyle(fontWeight: FontWeight.w600))),
            if (person.active)
              TextButton(
                  key: ValueKey('sharing-revoke-${person.userId}'),
                  onPressed: _busy ? null : () => _revokePerson(person),
                  child: const Text('Revoke access'))
            else
              Text('Access revoked', style: muted),
          ]),
          Text(
              '$mode${person.custom ? ' (custom)' : ''} · ${usage.requests} request${usage.requests == 1 ? '' : 's'} · about ${_duration(usage.approxSeconds)}'
              '${usage.lastUsedAt == null ? '' : ' · last used ${usage.lastUsedAt}'}',
              style: muted),
          if (person.active &&
              widget.memberAccessSource != null &&
              widget.personAccessSource != null)
            Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                    key: ValueKey('sharing-edit-${person.userId}'),
                    onPressed: _busy ? null : () => _editAccess(person),
                    child: const Text('Edit access'))),
          if (person.active)
            Row(children: [
              Text('At once:', style: muted),
              const SizedBox(width: 8),
              DropdownButton<int>(
                  key: ValueKey('sharing-quota-${person.userId}'),
                  value: person.maxConcurrentRequests.clamp(1, 10),
                  items: [
                    for (var n = 1; n <= 10; n++)
                      DropdownMenuItem(value: n, child: Text('$n'))
                  ],
                  onChanged: _busy
                      ? null
                      : (value) {
                          if (value == null) return;
                          unawaited(_act(() => widget.source.setPersonQuota(
                              widget.workspaceId, person.userId, value)));
                        }),
              const SizedBox(width: 16),
              Text('Run time per month:', style: muted),
              const SizedBox(width: 8),
              DropdownButton<int?>(
                  key: ValueKey('sharing-runtime-${person.userId}'),
                  value: _runTimeHours.contains(_hours(person))
                      ? _hours(person)
                      : null,
                  items: [
                    for (final hours in _runTimeHours)
                      DropdownMenuItem<int?>(
                          value: hours,
                          child: Text(hours == null ? 'No limit' : '$hours h'))
                  ],
                  onChanged: _busy
                      ? null
                      : (hours) => unawaited(_act(() => widget.source
                          .setPersonRunTimeLimit(
                              widget.workspaceId,
                              person.userId,
                              hours == null ? null : hours * 3600)))),
            ]),
          if (person.active && person.maxRunSecondsPerMonth != null)
            Text(
                'Used this month: about ${_duration(person.usage.monthSeconds)} of ${_duration(person.maxRunSecondsPerMonth!)}',
                style: muted),
        ]));
  }
}

/// Shown to a signed-in person who has been invited to use someone's
/// Workspace. Accepting only grants access; it adds no one to any Space.
class WorkspaceInvitationsBanner extends StatefulWidget {
  const WorkspaceInvitationsBanner({
    super.key,
    required this.source,
    this.onAccepted,
  });

  final AxWorkspaceSharingDataSource source;
  final VoidCallback? onAccepted;

  @override
  State<WorkspaceInvitationsBanner> createState() =>
      _WorkspaceInvitationsBannerState();
}

class _WorkspaceInvitationsBannerState
    extends State<WorkspaceInvitationsBanner> {
  List<AxMyWorkspaceInvitation> _invitations = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final next = await widget.source.loadMyWorkspaceInvitations();
      if (mounted) setState(() => _invitations = next);
    } catch (_) {
      // The banner is optional; a failed check simply shows nothing.
    }
  }

  Future<void> _accept(AxMyWorkspaceInvitation invitation) async {
    setState(() => _busy = true);
    try {
      await widget.source.acceptWorkspaceInvitation(invitation.id);
      widget.onAccepted?.call();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showNotice(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_invitations.isEmpty) return const SizedBox.shrink();
    return Column(children: [
      for (final invitation in _invitations)
        Card(
            key: ValueKey('workspace-invitation-${invitation.id}'),
            child: ListTile(
                title: Text(
                    '${invitation.ownerName} invited you to use ${invitation.workspaceName}'),
                subtitle: const Text(
                    'Accepting lets your own Spaces run on it. The owner sees usage only.'),
                trailing: FilledButton(
                    key: ValueKey(
                        'accept-workspace-invitation-${invitation.id}'),
                    onPressed: _busy ? null : () => _accept(invitation),
                    child: const Text('Accept')))),
    ]);
  }
}
