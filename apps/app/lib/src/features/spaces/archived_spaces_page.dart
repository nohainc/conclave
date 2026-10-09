import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_models.dart';
import '../../ax/sync/ax_archived_spaces.dart';
import '../../ax/sync/ax_collaboration_mutations.dart';
import '../../ax/sync/ax_query_builder.dart';
import '../../ax/sync/ax_sync_engine.dart';

class ArchivedSpacesPage extends StatefulWidget {
  const ArchivedSpacesPage({
    super.key,
    required this.archivedSpaces,
    required this.mutations,
  });

  final AxArchivedSpaces archivedSpaces;
  final AxCollaborationMutations mutations;

  @override
  State<ArchivedSpacesPage> createState() => _ArchivedSpacesPageState();
}

class _ArchivedSpacesPageState extends State<ArchivedSpacesPage> {
  final _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _ensure();
  }

  @override
  void didUpdateWidget(ArchivedSpacesPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.archivedSpaces != widget.archivedSpaces) _ensure();
  }

  void _ensure() => unawaited(widget.archivedSpaces
      .ensure()
      .then<void>((_) {}, onError: (Object _, StackTrace __) {}));

  @override
  Widget build(BuildContext context) => AxQueryBuilder<List<AxSpace>>(
        engine: widget.archivedSpaces.engine,
        query: widget.archivedSpaces.query,
        ensure: false,
        builder: (context, state) {
          final spaces = state.data ?? const <AxSpace>[];
          final isTwoColumn = MediaQuery.sizeOf(context).width >= 760;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Archived Spaces',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              const Text('Spaces you archived are kept here until restored.'),
              const SizedBox(height: 20),
              _ReadStatus(spaces: widget.archivedSpaces, state: state),
              if (state.hasData && spaces.isEmpty)
                const Text(
                    'Archived Spaces will appear here when you archive a Space.'),
              if (spaces.isNotEmpty)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final width = isTwoColumn
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final space in spaces)
                          SizedBox(width: width, child: _card(space)),
                      ],
                    );
                  },
                ),
            ],
          );
        },
      );

  Widget _card(AxSpace space) => Card(
        key: ValueKey('archived-space-${space.id}'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                space.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 10),
              Text(
                space.description.trim().isEmpty
                    ? 'No description'
                    : space.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 14),
              Align(
                alignment: Alignment.centerRight,
                child: Wrap(
                  spacing: 8,
                  children: [
                    FilledButton.tonal(
                      key: ValueKey('restore-archived-space-${space.id}'),
                      onPressed: _busy.contains(space.id)
                          ? null
                          : () => _restore(space),
                      child: Text(
                          _busy.contains(space.id) ? 'Restoring…' : 'Restore'),
                    ),
                    OutlinedButton(
                      key: ValueKey('delete-archived-space-${space.id}'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Theme.of(context).colorScheme.error),
                      onPressed: _busy.contains(space.id)
                          ? null
                          : () => _confirmDelete(space),
                      child: Text(
                          _busy.contains(space.id) ? 'Deleting…' : 'Delete'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _restore(AxSpace space) async {
    setState(() => _busy.add(space.id));
    try {
      await widget.mutations.editSpace(
        space,
        settings: const {'archived': false},
      );
      await widget.archivedSpaces.refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(space.id));
    }
  }

  Future<void> _confirmDelete(AxSpace space) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${space.name}?'),
        content: const Text(
            'This permanently deletes the Space and its archived record.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy.add(space.id));
    try {
      await widget.mutations.deleteSpace(space);
      await widget.archivedSpaces.refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(space.id));
    }
  }
}

class _ReadStatus extends StatelessWidget {
  const _ReadStatus({required this.spaces, required this.state});

  final AxArchivedSpaces spaces;
  final AxQueryState<List<AxSpace>> state;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.isFetching)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: LinearProgressIndicator(),
            ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      state.hasData
                          ? 'Archived Spaces could not be updated. Cached details remain available.'
                          : 'Archived Spaces could not be loaded. Check your connection.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(spaces.refresh().then<void>(
                        (_) {},
                        onError: (Object _, StackTrace __) {})),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
        ],
      );
}
