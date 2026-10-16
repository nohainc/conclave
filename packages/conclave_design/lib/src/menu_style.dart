import 'package:flutter/material.dart';

import 'colors.dart';

/// Shared surface and row styling for application and composer menus.
abstract final class ConclaveMenuStyle {
  static const padding = EdgeInsets.all(6);
  static const textStyle =
      TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500);

  static Color background(bool isDark) =>
      ConclaveColors.navigationBackground(isDark);

  static Color shadow(bool isDark) =>
      Colors.black.withValues(alpha: isDark ? 0.7 : 0.18);

  static RoundedRectangleBorder shape(bool isDark) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: ConclaveColors.navigationBorder(isDark)),
      );

  static MenuStyle surface(bool isDark, {bool composer = false}) => MenuStyle(
        backgroundColor: WidgetStatePropertyAll(composer
            ? ConclaveColors.composerBackground(isDark)
            : background(isDark)),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(12),
        shadowColor: WidgetStatePropertyAll(shadow(isDark)),
        shape: WidgetStatePropertyAll(shape(isDark)),
        padding: const WidgetStatePropertyAll(padding),
      );

  static ButtonStyle item(bool isDark, {bool isDestructive = false}) =>
      ButtonStyle(
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        minimumSize: const WidgetStatePropertyAll(Size(196, 36)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        textStyle: const WidgetStatePropertyAll(textStyle),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return isDestructive
                ? ConclaveColors.error.withValues(alpha: 0.12)
                : ConclaveColors.navigationHover(isDark);
          }
          return null;
        }),
      );
}

/// A popup route entry whose child owns focus, hover, and activation.
/// Avoid nesting PopupMenuItem's InkWell around a MenuItemButton.
class ConclaveMenuEntry<T> extends PopupMenuEntry<T> {
  const ConclaveMenuEntry(
      {super.key, required this.value, required this.child});

  final T value;
  final Widget child;

  @override
  double get height => 36;

  @override
  bool represents(T? value) => this.value == value;

  @override
  State<ConclaveMenuEntry<T>> createState() => _ConclaveMenuEntryState<T>();
}

class _ConclaveMenuEntryState<T> extends State<ConclaveMenuEntry<T>> {
  @override
  Widget build(BuildContext context) => widget.child;
}
