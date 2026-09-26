import 'package:flutter/material.dart';

import 'workspace_enrollment.dart';

class WorkspacePairingRequest {
  const WorkspacePairingRequest({
    required this.cloudUrl,
    required this.token,
    required this.workspaceName,
  });

  final String cloudUrl;
  final String token;
  final String workspaceName;
}

Future<WorkspacePairingRequest?> showWorkspacePairingDialog(
  BuildContext context, {
  String initialCloudUrl = conclaveProductionCloudUrl,
  String? initialWorkspaceName,
}) {
  return showDialog<WorkspacePairingRequest>(
    context: context,
    builder: (context) => _WorkspacePairingDialog(
      initialCloudUrl: initialCloudUrl,
      initialWorkspaceName: initialWorkspaceName,
    ),
  );
}

class _WorkspacePairingDialog extends StatefulWidget {
  const _WorkspacePairingDialog({
    required this.initialCloudUrl,
    this.initialWorkspaceName,
  });

  final String initialCloudUrl;
  final String? initialWorkspaceName;

  @override
  State<_WorkspacePairingDialog> createState() =>
      _WorkspacePairingDialogState();
}

class _WorkspacePairingDialogState extends State<_WorkspacePairingDialog> {
  late final TextEditingController _workspaceName;
  late final TextEditingController _token;
  late final TextEditingController _cloudUrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _workspaceName =
        TextEditingController(text: widget.initialWorkspaceName ?? '');
    _token = TextEditingController();
    _cloudUrl = TextEditingController(text: widget.initialCloudUrl);
  }

  @override
  void dispose() {
    _workspaceName.dispose();
    _token.dispose();
    _cloudUrl.dispose();
    super.dispose();
  }

  void _submit() {
    final workspaceName = _workspaceName.text.trim();
    final token = _token.text.trim();
    final cloudUrl = _cloudUrl.text.trim();
    final uri = Uri.tryParse(cloudUrl);
    if (workspaceName.isEmpty) {
      setState(() => _error = 'Enter a workspace display name.');
      return;
    }
    if (token.isEmpty) {
      setState(() => _error = 'Enter the pairing code from Conclave AX.');
      return;
    }
    if (uri == null ||
        !const {'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      setState(() => _error = 'Enter a valid Conclave Cloud URL.');
      return;
    }
    Navigator.of(context).pop(
      WorkspacePairingRequest(
        cloudUrl: cloudUrl,
        token: token,
        workspaceName: workspaceName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pair Conclave Workspace'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'In Conclave AX, open the Workspace you want this machine to use '
                  'and choose Connect machine. Paste the one-time pairing code here. '
                  'You can configure local Workers before pairing; pairing shares '
                  'only safe Worker inventory with Cloud. To switch an already '
                  'paired machine to a different Workspace, unpair it first in Workspace.',
                ),
                const SizedBox(height: 18),
                TextField(
                  controller: _workspaceName,
                  autocorrect: false,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Workspace display name',
                    helperText:
                        'Proposed from your computer name. You can customize it before pairing.',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _token,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(
                    labelText: 'Pairing code',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('Advanced'),
                  children: [
                    TextField(
                      controller: _cloudUrl,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Conclave Cloud URL',
                        helperText:
                            'Change this only for local or staging environments.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    _error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const Text('Pair'),
          ),
        ],
      );
}
