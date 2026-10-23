import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';
import 'note_editor.dart';

/// My Notes: every private note of the signed-in user, including notes from
/// Threads that were deleted or that the user can no longer open.
class NotesPage extends StatefulWidget {
  const NotesPage({super.key, required this.source, this.onOpenThread});

  final AxNotesDataSource source;
  final void Function(String spaceId, String threadId)? onOpenThread;

  @override
  State<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends State<NotesPage> {
  List<AxNote>? _notes;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    try {
      final notes = await widget.source.loadNotes();
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _error = null;
      });
    } on Object {
      if (mounted) setState(() => _error = 'Notes could not be loaded.');
    }
  }

  Future<void> _create() async {
    try {
      final note = await widget.source.createNote();
      if (!mounted) return;
      await _open(note);
    } on Object {
      if (mounted) setState(() => _error = 'The note could not be created.');
    }
  }

  Future<void> _open(AxNote note) async {
    await showDialog<void>(
      context: context,
      builder: (context) => _NoteDialog(
        note: note,
        source: widget.source,
        onOpenThread: note.linked && widget.onOpenThread != null
            ? () {
                Navigator.of(context).pop();
                widget.onOpenThread!(note.spaceId!, note.threadId!);
              }
            : null,
      ),
    );
    await _reload();
  }

  Future<void> _delete(AxNote note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete note'),
        content: Text('Delete "${note.displayTitle}"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          TextButton(
              key: const ValueKey('confirm-delete-note'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.source.deleteNote(note.id);
    } on Object {
      if (mounted) setState(() => _error = 'The note could not be deleted.');
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: Text('My Notes',
                style: Theme.of(context).textTheme.headlineMedium),
          ),
          FilledButton.icon(
            key: const ValueKey('new-note'),
            onPressed: () => unawaited(_create()),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New note'),
          ),
        ]),
        const SizedBox(height: 8),
        const Text('Private notes only you can see. Notes from a Thread stay '
            'here even if the Thread is deleted.'),
        const SizedBox(height: 20),
        if (_error != null) ...[
          Text(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
          const SizedBox(height: 12),
        ],
        if (notes == null && _error == null)
          const Center(child: CircularProgressIndicator())
        else if (notes != null && notes.isEmpty)
          const Text('No notes yet. Create one here or open the Notes tab in '
              'a Thread.')
        else if (notes != null)
          for (final note in notes)
            Card(
              key: ValueKey('note-${note.id}'),
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                onTap: () => unawaited(_open(note)),
                title: Text(note.displayTitle,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (note.threadId != null)
                      Text(
                        note.linked
                            ? 'Thread: ${note.threadName ?? ''}'
                            : 'From a Thread you can no longer open: '
                                '${note.threadName ?? ''}',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                    if (note.body.trim().isNotEmpty)
                      Text(note.body.trim(),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                ),
                trailing: IconButton(
                  key: ValueKey('delete-note-${note.id}'),
                  tooltip: 'Delete note',
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  onPressed: () => unawaited(_delete(note)),
                ),
              ),
            ),
      ],
    );
  }
}

class _NoteDialog extends StatelessWidget {
  const _NoteDialog(
      {required this.note, required this.source, this.onOpenThread});

  final AxNote note;
  final AxNotesDataSource source;
  final VoidCallback? onOpenThread;

  @override
  Widget build(BuildContext context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  if (note.threadId != null)
                    Expanded(
                      child: Text(
                        note.linked
                            ? 'Thread: ${note.threadName ?? ''}'
                            : 'From a Thread you can no longer open: '
                                '${note.threadName ?? ''}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  else
                    const Spacer(),
                  if (onOpenThread != null)
                    TextButton(
                        onPressed: onOpenThread,
                        child: const Text('Open Thread')),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ]),
                Expanded(
                  child: NoteEditor(
                    showTitle: true,
                    load: () => source.loadNote(note.id),
                    save: ({required title, required body, revision}) =>
                        source.updateNote(note.id,
                            title: title,
                            body: body,
                            revision: revision ?? note.revision),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
