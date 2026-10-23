import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';

typedef NoteSave = Future<AxNote> Function(
    {required String title, required String body, int? revision});

/// Plain-text editor for one private note. Text saves automatically shortly
/// after typing stops and when the editor closes. A save that lost to a newer
/// version (another device) reloads the latest text instead of overwriting it.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.load,
    required this.save,
    this.showTitle = false,
    this.hint = 'Write private notes…',
    this.saveDelay = const Duration(milliseconds: 800),
    this.onSaved,
  });

  /// Loads the note; null means it does not exist yet (first save creates it).
  final Future<AxNote?> Function() load;
  final NoteSave save;
  final bool showTitle;
  final String hint;
  final Duration saveDelay;
  final ValueChanged<AxNote>? onSaved;

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  AxNote? _note;
  bool _loading = true;
  String? _error;
  String? _status;
  Timer? _timer;
  Future<void>? _saving;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_dirty) unawaited(_save());
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _load({String? status}) async {
    try {
      final note = await widget.load();
      if (!mounted) return;
      setState(() {
        _note = note;
        _title.text = note?.title ?? '';
        _body.text = note?.body ?? '';
        _loading = false;
        _error = null;
        _dirty = false;
        _status = status;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Notes could not be loaded.';
      });
    }
  }

  void _changed() {
    _dirty = true;
    _timer?.cancel();
    _timer = Timer(widget.saveDelay, () => unawaited(_save()));
    if (_status != null && mounted) setState(() => _status = null);
  }

  Future<void> _save() async {
    if (!_dirty) return;
    // Read the text now: this also runs from dispose, before the
    // controllers go away.
    _dirty = false;
    final title = _title.text;
    final body = _body.text;
    // One save at a time, in order, each with the latest revision.
    while (_saving != null) {
      await _saving;
    }
    final saving = () async {
      try {
        final saved = await widget.save(
            title: title, body: body, revision: _note?.revision);
        _note = saved;
        widget.onSaved?.call(saved);
        if (mounted) setState(() => _status = 'Saved');
      } on AxApiException catch (error) {
        if (error.statusCode == 409) {
          if (mounted) {
            await _load(
                status: 'This note changed elsewhere. Showing the latest '
                    'version.');
          }
        } else {
          _dirty = true;
          if (mounted) setState(() => _status = 'Not saved. Retrying…');
          _timer?.cancel();
          if (mounted) {
            _timer =
                Timer(const Duration(seconds: 5), () => unawaited(_save()));
          }
        }
      } on Object {
        _dirty = true;
        if (mounted) setState(() => _status = 'Not saved. Retrying…');
        _timer?.cancel();
        if (mounted) {
          _timer = Timer(const Duration(seconds: 5), () => unawaited(_save()));
        }
      }
    }();
    _saving = saving;
    try {
      await saving;
    } finally {
      _saving = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_error!),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              setState(() => _loading = true);
              unawaited(_load());
            },
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showTitle)
          TextField(
            key: const ValueKey('note-title'),
            controller: _title,
            onChanged: (_) => _changed(),
            maxLength: 200,
            style: Theme.of(context).textTheme.titleMedium,
            decoration: const InputDecoration(
              hintText: 'Title',
              border: InputBorder.none,
              counterText: '',
            ),
          ),
        Expanded(
          child: TextField(
            key: const ValueKey('note-body'),
            controller: _body,
            onChanged: (_) => _changed(),
            maxLines: null,
            expands: true,
            maxLength: 200000,
            textAlignVertical: TextAlignVertical.top,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              hintText: widget.hint,
              border: InputBorder.none,
              counterText: '',
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.lock_outline_rounded, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _status ?? 'Only you can see these notes.',
              key: const ValueKey('note-status'),
              style: TextStyle(fontSize: 12, color: muted),
            ),
          ),
        ]),
      ],
    );
  }
}
