import 'package:flutter/material.dart';

import 'workspace_enrollment.dart';

class WorkspacePairingRequest {
  const WorkspacePairingRequest({
    required this.cloudUrl,
    required this.token,
  });

  final String cloudUrl;
  final String token;
}

Future<WorkspacePairingRequest?> showWorkspacePairingDialog(
  BuildContext context, {
  String initialCloudUrl = conclaveProductionCloudUrl,
}) {
  return showDialog<WorkspacePairingRequest>(
    context: context,
    builder: (context) => _WorkspacePairingDialog(
      initialCloudUrl: initialCloudUrl,
    ),
  );
}

class _WorkspacePairingDialog extends StatefulWidget {
  const _WorkspacePairingDialog({required this.initialCloudUrl});

  final String initialCloudUrl;

  @override
  State<_WorkspacePairingDialog> createState() =>
      _WorkspacePairingDialogState();
}

class _WorkspacePairingDialogState extends State<_WorkspacePairingDialog> {
  late final TextEditingController _token;
  late final TextEditingController _cloudUrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _token = TextEditingController();
    _cloudUrl = TextEditingController(text: widget.initialCloudUrl);
  }

  @override
  void dispose() {
    _token.dispose();
    _cloudUrl.dispose();
    super.dispose();
  }

  void _submit() {
    final token = _token.text.trim();
    final cloudUrl = _cloudUrl.text.trim();
    final uri = Uri.tryParse(cloudUrl);
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
      WorkspacePairingRequest(cloudUrl: cloudUrl, token: token),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pair Conclave Workspace'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'In Conclave AX, open the Workspace and choose Connect machine. '
                'Paste the one-time pairing code here.',
              ),
              const SizedBox(height: 18),
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
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
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
