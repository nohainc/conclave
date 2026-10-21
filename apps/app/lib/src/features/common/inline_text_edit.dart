import 'package:flutter/material.dart';

/// A value shown as text with an edit button that turns into a field in
/// place. Used instead of a dialog for one-field edits on a page.
class InlineTextEdit extends StatefulWidget {
  const InlineTextEdit({
    super.key,
    required this.value,
    required this.tooltip,
    required this.label,
    required this.onSave,
  });

  final String value;
  final String tooltip;
  final String label;

  /// Saves the trimmed, non-empty value. Returns an error or null.
  final Future<String?> Function(String value) onSave;

  @override
  State<InlineTextEdit> createState() => _InlineTextEditState();
}

class _InlineTextEditState extends State<InlineTextEdit> {
  final _controller = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _start() => setState(() {
        _controller.text = widget.value;
        _error = null;
        _editing = true;
      });

  Future<void> _save() async {
    final value = _controller.text.trim();
    if (value.isEmpty) {
      setState(() => _error = '${widget.label} cannot be empty.');
      return;
    }
    if (value == widget.value) {
      setState(() => _editing = false);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onSave(value);
    } catch (failure) {
      error = failure.toString();
    }
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
      if (error == null) _editing = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_editing) {
      return Row(
        children: [
          Flexible(child: Text(widget.value, overflow: TextOverflow.ellipsis)),
          IconButton(
            tooltip: widget.tooltip,
            onPressed: _start,
            icon: const Icon(Icons.edit_outlined, size: 17),
          ),
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('inline-text-edit-field'),
              controller: _controller,
              autofocus: true,
              enabled: !_saving,
              textInputAction: TextInputAction.done,
              decoration:
                  InputDecoration(labelText: widget.label, errorText: _error),
              onSubmitted: (_) => _save(),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _saving ? null : () => setState(() => _editing = false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
    );
  }
}
