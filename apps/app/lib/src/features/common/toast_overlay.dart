import 'package:flutter/material.dart';
import '../../brand.dart';

/// Type of Toast notification
enum ToastType { success, info, warning, error }

/// Represents a single active toast message
class ToastMessage {
  const ToastMessage({
    required this.id,
    required this.message,
    required this.type,
    this.duration = const Duration(seconds: 4),
  });

  final String id;
  final String message;
  final ToastType type;
  final Duration duration;
}

/// Floating top-right Toast notification banner overlay
class ToastOverlay extends StatelessWidget {
  const ToastOverlay({
    super.key,
    required this.toasts,
    required this.onDismiss,
  });

  final List<ToastMessage> toasts;
  final ValueChanged<String> onDismiss;

  @override
  Widget build(BuildContext context) {
    if (toasts.isEmpty) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Positioned(
      top: 16,
      right: 16,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: toasts.map((toast) {
            Color accentColor;
            IconData icon;
            Color bgColor;

            switch (toast.type) {
              case ToastType.success:
                accentColor = ConclaveBrand.success;
                bgColor = isDark ? ConclaveBrand.successWashDark : ConclaveBrand.successWash;
                icon = Icons.check_circle_outline_rounded;
                break;
              case ToastType.warning:
                accentColor = ConclaveBrand.warning;
                bgColor = isDark ? ConclaveBrand.warningWashDark : ConclaveBrand.warningWash;
                icon = Icons.warning_amber_rounded;
                break;
              case ToastType.error:
                accentColor = ConclaveBrand.error;
                bgColor = isDark ? ConclaveBrand.errorWashDark : ConclaveBrand.errorWash;
                icon = Icons.error_outline_rounded;
                break;
              case ToastType.info:
                accentColor = ConclaveBrand.info;
                bgColor = isDark ? ConclaveBrand.infoWashDark : ConclaveBrand.infoWash;
                icon = Icons.info_outline_rounded;
                break;
            }

            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              constraints: const BoxConstraints(maxWidth: 380),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isDark ? ConclaveBrand.darkSurface : ConclaveBrand.lightSurface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: accentColor.withValues(alpha: 0.4), width: 1.2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.08),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: bgColor,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 18, color: accentColor),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: Text(
                      toast.message,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: isDark ? ConclaveBrand.darkInk : ConclaveBrand.lightInk,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 16),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                    splashRadius: 14,
                    color: isDark ? ConclaveBrand.darkInkMuted : ConclaveBrand.lightInkMuted,
                    onPressed: () => onDismiss(toast.id),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}
