import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';

/// Shared Create/Rename/Delete Thread dialogs used by the sidebar and the
/// Space page, so both surfaces behave the same.

/// Asks for a new Thread name. Returns the trimmed name, or null if cancelled.
/// Names for which [isNameTaken] returns true are rejected; it is checked on
/// submit so it sees the latest Thread list.
Future<String?> showCreateThreadDialog(
  BuildContext context, {
  bool Function(String name)? isNameTaken,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ThreadNameDialog(
      title: 'Create Thread',
      confirmLabel: 'Create Thread',
      initialName: '',
      isNameTaken: isNameTaken,
    ),
  );
}

/// Asks for a new name for [currentName]. Returns the trimmed name only when
/// it changed; null if cancelled or unchanged.
Future<String?> showRenameThreadDialog(
  BuildContext context, {
  required String currentName,
  bool Function(String name)? isNameTaken,
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (_) => _ThreadNameDialog(
      title: 'Rename Thread',
      confirmLabel: 'Rename',
      initialName: currentName,
      isNameTaken: isNameTaken,
    ),
  );
  if (name == null || name == currentName.trim()) return null;
  return name;
}

/// Confirms permanent deletion of a Thread.
Future<bool> confirmDeleteThread(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      constraints: ConclaveDialogStyle.small,
      title: const Text('Delete Thread'),
      content: const Text(
        'Permanently delete this Thread and all its history? This action cannot be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          style: ConclaveDialogStyle.destructiveButton(),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed == true;
}

class _ThreadNameDialog extends StatefulWidget {
  const _ThreadNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialName,
    this.isNameTaken,
  });

  final String title;
  final String confirmLabel;
  final String initialName;
  final bool Function(String name)? isNameTaken;

  @override
  State<_ThreadNameDialog> createState() => _ThreadNameDialogState();
}

class _ThreadNameDialogState extends State<_ThreadNameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName)
        ..addListener(_onTextChanged);
  late String _lastText = widget.initialName;
  String? _errorText;

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  // The controller also notifies on selection changes; only clear the
  // error when the text itself changes.
  void _onTextChanged() {
    if (_controller.text == _lastText) return;
    _lastText = _controller.text;
    setState(() => _errorText = null);
  }

  void _submit() {
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) return;
    final lower = trimmed.toLowerCase();
    final unchanged = lower == widget.initialName.trim().toLowerCase();
    final taken = !unchanged && (widget.isNameTaken?.call(trimmed) ?? false);
    if (taken) {
      setState(() => _errorText = 'A thread with this name already exists.');
      return;
    }
    Navigator.pop(context, trimmed);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 1,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(
          labelText: 'Thread name',
          errorText: _errorText,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _controller.text.trim().isEmpty ? null : _submit,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
