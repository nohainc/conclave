import 'package:flutter/material.dart';

import '../controllers/profile_lab_controller.dart';
import '../profile_lab_cloud_config.dart';
import '../theme/profile_lab_theme.dart';

class CloudSettingsDialog extends StatefulWidget {
  const CloudSettingsDialog({super.key, required this.controller});

  final ProfileLabController controller;

  static Future<void> show(
    BuildContext context,
    ProfileLabController controller,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => CloudSettingsDialog(controller: controller),
    );
  }

  @override
  State<CloudSettingsDialog> createState() => _CloudSettingsDialogState();
}

class _CloudSettingsDialogState extends State<CloudSettingsDialog> {
  late final TextEditingController _originController;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _originController = TextEditingController(text: widget.controller.cloudUrl);
  }

  @override
  void dispose() {
    _originController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await widget.controller.setCloudUrl(_originController.text);
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _reset() async {
    setState(() {
      _error = null;
      _saving = true;
    });
    try {
      await widget.controller.resetCloudUrl();
      if (mounted) Navigator.of(context).pop();
    } on Object catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cloud connection'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _originController,
              enabled: !_saving,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Cloud origin',
                hintText: 'https://app.example.com',
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 10),
            Text(
              'Build default: ${ProfileLabCloudConfig.buildDefaultOrigin}',
              style: const TextStyle(
                  fontSize: 12, color: ProfileLabTheme.secondaryText),
            ),
            const SizedBox(height: 8),
            const Text(
              'HTTPS is required for remote Cloud. Development builds may use HTTP on localhost or loopback. Changing the origin clears the current local sign-in.',
              style:
                  TextStyle(fontSize: 12, color: ProfileLabTheme.secondaryText),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(
                    color: ProfileLabTheme.failColor, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : _reset,
          child: const Text('Reset to build default'),
        ),
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}
