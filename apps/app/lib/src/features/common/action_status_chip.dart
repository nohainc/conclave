import 'package:flutter/material.dart';
import 'package:syntila_design/syntila_design.dart';

import '../../ax/ax_action_status.dart';

/// The shared badge for a live action's stage; see [AxActionStatus].
class ActionStatusChip extends StatelessWidget {
  const ActionStatusChip({super.key, required this.status, required this.kind});

  final AxActionStatus status;
  final AxActionKind kind;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final (soft, text) = switch (status) {
      AxActionStatus.failed => (
          SyntilaColors.errorSoft(isDark),
          SyntilaColors.errorText(isDark)
        ),
      AxActionStatus.expired || AxActionStatus.revoked => (
          SyntilaColors.neutralSoft(isDark),
          SyntilaColors.neutralText(isDark)
        ),
      AxActionStatus.processed || AxActionStatus.responded => (
          SyntilaColors.successSoft(isDark),
          SyntilaColors.successText(isDark)
        ),
      AxActionStatus.sending || AxActionStatus.accepted => (
          SyntilaColors.warningSoft(isDark),
          SyntilaColors.warningText(isDark)
        ),
      _ => (SyntilaColors.infoSoft(isDark), SyntilaColors.infoText(isDark)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: soft,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: text.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.label(kind).toUpperCase(),
        style:
            TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: text),
      ),
    );
  }
}
