import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void showCopyableErrorSnackBar(BuildContext context, String message) {
  showCopyableMessageSnackBar(
    context,
    message,
    isError: true,
    duration: const Duration(seconds: 20),
  );
}

/// Shows a copyable message while preserving the caller's chosen timeout.
void showCopyableMessageSnackBar(
  BuildContext context,
  String message, {
  bool isError = false,
  Duration duration = const Duration(seconds: 4),
}) {
  final colors = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      duration: duration,
      backgroundColor: isError ? colors.error : null,
      content: Row(
        children: [
          Expanded(child: SelectableText(message)),
          IconButton(
            tooltip: isError ? 'Copy error message' : 'Copy message',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 18),
            color: isError ? colors.onError : colors.onInverseSurface,
            onPressed: () => copyMessageToClipboard(
              context,
              message,
              confirmation: isError ? 'Error message copied' : null,
            ),
          ),
        ],
      ),
    ),
  );
}

Future<void> copyMessageToClipboard(
  BuildContext context,
  String message, {
  String? confirmation,
}) async {
  await Clipboard.setData(ClipboardData(text: message));
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(confirmation ?? 'Message copied to clipboard'),
      duration: const Duration(seconds: 1),
    ),
  );
}

class CopyableMessageText extends StatelessWidget {
  const CopyableMessageText(
    this.message, {
    this.style,
    this.iconColor,
    this.tooltip = 'Copy message',
    super.key,
  });

  final String message;
  final TextStyle? style;
  final Color? iconColor;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            fit: FlexFit.loose,
            child: Text(message, style: style),
          ),
          IconButton(
            tooltip: tooltip,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const Icon(Icons.copy, size: 18),
            color: iconColor ?? Theme.of(context).colorScheme.onSurfaceVariant,
            onPressed: () => copyMessageToClipboard(
              context,
              message,
              confirmation: tooltip == 'Copy error message'
                  ? 'Error message copied'
                  : null,
            ),
          ),
        ],
      );
}
