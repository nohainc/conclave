import 'package:flutter/material.dart';

import 'colors.dart';
import 'menu_style.dart';
import 'typography.dart';

/// Shared surface, typography, and width limits for application dialogs.
///
/// The theme applies [medium] to every dialog; confirmations opt into
/// [small] and content dialogs into [large] so no dialog grows with the
/// available window width.
abstract final class SyntilaDialogStyle {
  static const small = BoxConstraints(minWidth: 280, maxWidth: 400);
  static const medium = BoxConstraints(minWidth: 280, maxWidth: 480);
  static const large = BoxConstraints(minWidth: 280, maxWidth: 640);

  static const radius = 14.0;
  static const insetPadding =
      EdgeInsets.symmetric(horizontal: 24, vertical: 24);

  static Color background(bool isDark) => SyntilaColors.surface(isDark);

  static RoundedRectangleBorder shape(bool isDark) => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(color: SyntilaColors.border(isDark)),
      );

  static DialogThemeData theme(bool isDark) => DialogThemeData(
        backgroundColor: background(isDark),
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shadowColor: SyntilaMenuStyle.shadow(isDark),
        shape: shape(isDark),
        insetPadding: insetPadding,
        constraints: medium,
        titleTextStyle: TextStyle(
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: SyntilaColors.textPrimary(isDark),
        ),
        contentTextStyle: TextStyle(
          fontFamily: SyntilaTypography.fontFamily,
          fontFamilyFallback: SyntilaTypography.fontFamilyFallback,
          fontSize: 13,
          height: 1.45,
          color: SyntilaColors.textSecondary(isDark),
        ),
      );

  /// Filled button style for destructive confirmations.
  static ButtonStyle destructiveButton() =>
      FilledButton.styleFrom(backgroundColor: SyntilaColors.error);
}
