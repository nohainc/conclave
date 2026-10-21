import 'package:flutter/material.dart';

import '../brand.dart';
import 'ax_models.dart';

/// Two-step email change: a code from the new address, then one from the
/// current address. Pops with the applied email, or null when cancelled.
class EmailChangeDialog extends StatefulWidget {
  const EmailChangeDialog({
    super.key,
    required this.currentEmail,
    required this.requestCode,
    required this.verifyNewEmail,
    required this.confirm,
  });

  final String currentEmail;
  final Future<AxEmailChangeStep> Function(String newEmail) requestCode;
  final Future<AxEmailChangeStep> Function(String code) verifyNewEmail;
  final Future<String> Function(String code) confirm;

  @override
  State<EmailChangeDialog> createState() => _EmailChangeDialogState();
}

enum _EmailChangeStage { enterEmail, newCode, currentCode }

class _EmailChangeDialogState extends State<EmailChangeDialog> {
  final _emailController = TextEditingController();
  final _codeController = TextEditingController();
  var _stage = _EmailChangeStage.enterEmail;
  var _busy = false;
  String? _error;
  String _newEmail = '';

  @override
  void dispose() {
    _emailController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    switch (_stage) {
      case _EmailChangeStage.enterEmail:
        final email = _emailController.text.trim();
        if (email.isEmpty) return;
        _run(() async {
          final step = await widget.requestCode(email);
          if (!mounted) return;
          setState(() {
            _newEmail = step.email.isEmpty ? email : step.email;
            _codeController.clear();
            _stage = _EmailChangeStage.newCode;
          });
        });
      case _EmailChangeStage.newCode:
        final code = _codeController.text.trim();
        if (code.isEmpty) return;
        _run(() async {
          await widget.verifyNewEmail(code);
          if (!mounted) return;
          setState(() {
            _codeController.clear();
            _stage = _EmailChangeStage.currentCode;
          });
        });
      case _EmailChangeStage.currentCode:
        final code = _codeController.text.trim();
        if (code.isEmpty) return;
        _run(() async {
          final email = await widget.confirm(code);
          if (mounted) Navigator.of(context).pop(email);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enteringEmail = _stage == _EmailChangeStage.enterEmail;
    final prompt = switch (_stage) {
      _EmailChangeStage.enterEmail =>
        'Enter your new email address. We will send it a one-time code.',
      _EmailChangeStage.newCode => 'Enter the 6-digit code sent to $_newEmail.',
      _EmailChangeStage.currentCode =>
        'To finish, enter the 6-digit code sent to your current address, '
            '${widget.currentEmail}.',
    };
    return AlertDialog(
      title: const Text('Update email'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(prompt),
          const SizedBox(height: 12),
          if (enteringEmail)
            TextField(
              key: const ValueKey('email-change-new-email'),
              controller: _emailController,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'New email address'),
              onSubmitted: (_) => _submit(),
            )
          else
            TextField(
              key: ValueKey('email-change-code-${_stage.name}'),
              controller: _codeController,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              maxLength: 6,
              decoration: const InputDecoration(labelText: 'Verification code'),
              onSubmitted: (_) => _submit(),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: TextStyle(
                    color: ConclaveColors.errorText(
                        Theme.of(context).brightness == Brightness.dark)),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: Text(switch (_stage) {
            _EmailChangeStage.enterEmail => 'Send code',
            _EmailChangeStage.newCode => 'Verify',
            _EmailChangeStage.currentCode => 'Update email',
          }),
        ),
      ],
    );
  }
}

/// Requires the user to retype their account email before deletion.
/// Pops with the typed email when confirmed, or null when cancelled.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.email});

  final String email;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _controller = TextEditingController();

  bool get _matches =>
      widget.email.isNotEmpty &&
      _controller.text.trim().toLowerCase() ==
          widget.email.trim().toLowerCase();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Delete account?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'This permanently deletes your Conclave account and signs you out on every device. This action cannot be undone.'),
            const SizedBox(height: 12),
            Text('Type ${widget.email} to confirm.'),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('delete-account-confirm-email'),
              controller: _controller,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email address'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_matches) {
                  Navigator.of(context).pop(_controller.text.trim());
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: ConclaveDialogStyle.destructiveButton(),
            onPressed: _matches
                ? () => Navigator.of(context).pop(_controller.text.trim())
                : null,
            child: const Text('Delete account'),
          ),
        ],
      );
}
