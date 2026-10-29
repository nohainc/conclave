import 'dart:async';

import 'package:flutter/material.dart';

import '../../ax/ax_data.dart';

/// Reciprocal read receipts: off hides when you read Threads and when others
/// read your messages ("Seen by").
class ReadReceiptPrivacyToggle extends StatefulWidget {
  const ReadReceiptPrivacyToggle({super.key, required this.source});

  final AxReadReceiptPrivacyDataSource source;

  @override
  State<ReadReceiptPrivacyToggle> createState() =>
      _ReadReceiptPrivacyToggleState();
}

class _ReadReceiptPrivacyToggleState extends State<ReadReceiptPrivacyToggle> {
  bool? _share;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.source.loadShareReadReceipts().then((value) {
      if (mounted) setState(() => _share = value);
    }, onError: (Object _) {
      if (mounted) setState(() => _share = true);
    }));
  }

  Future<void> _change(bool value) async {
    final previous = _share;
    setState(() {
      _share = value;
      _saving = true;
    });
    try {
      await widget.source.setShareReadReceipts(value);
    } catch (_) {
      if (mounted) setState(() => _share = previous);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        key: const ValueKey('profile-read-receipts'),
        contentPadding: EdgeInsets.zero,
        title: const Text('Read receipts'),
        subtitle: const Text(
            'Show people when you have read their messages. When off, you '
            'also won\'t see when they read yours.'),
        value: _share ?? true,
        onChanged: _share == null || _saving ? null : _change,
      );
}
