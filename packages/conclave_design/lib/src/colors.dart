import 'package:flutter/material.dart';

/// Semantic brand colors and design tokens for Syntila.
abstract final class ConclaveColors {
  // Brand Core
  static const primary = Color(0xff5e20f8);
  static const primaryPressed = Color(0xff510ddc);
  static const primaryForegroundLight = Color(0xff5e20f8);
  static const primaryForegroundDark = Color(0xffcaccff);
  static const primarySoft = Color(0xffd9dbfc);
  static const primarySoftDark = Color(0xff221d51);

  // Focused input field: border and floating label. Mirrored across themes
  // like the text ramp (light + dark lightness = 117); the label sits 6
  // points further from the field background than the border.
  static const focusBorderLight = Color(0xff5e1ff7);
  static const focusBorderDark = Color(0xff8881ff);
  static const focusLabelLight = Color(0xff4f02d9);
  static const focusLabelDark = Color(0xff9c9aff);
  static Color focusBorder(bool isDark) =>
      isDark ? focusBorderDark : focusBorderLight;
  static Color focusLabel(bool isDark) =>
      isDark ? focusLabelDark : focusLabelLight;

  // Light Mode Surfaces & Inks
  static const canvasLight = Color(0xffeff0ff);
  static const surfaceLight = Color(0xfffbfbff);
  static const surfaceHoverLight = Color(0xffe6e7f5);
  static const borderLight = Color(0xffd2d3e1);
  static const textPrimaryLight = Color(0xff171721);
  static const textSecondaryLight = Color(0xff33343f);
  static const codeBackgroundLight = Color(0xffe6e7f5);

  // Dark Mode Surfaces & Inks
  static const canvasDark = Color(0xff171721);
  static const surfaceDark = Color(0xff1f1e29);
  static const surfaceHoverDark = Color(0xff242530);
  static const borderDark = Color(0xff2d2d38);
  static const textPrimaryDark = Color(0xffeff0ff);
  static const textSecondaryDark = Color(0xffc8c9d7);
  static const codeBackgroundDark = Color(0xff10101a);

  // Navigation Tokens
  static const navigationBackgroundLight = Color(0xffe6e7f5);
  static const navigationBackgroundDark = Color(0xff10101a);
  static const navigationRaisedLight = Color(0xffeff0ff);
  static const navigationRaisedDark = Color(0xff10101a);
  static const navigationHoverLight = Color(0xffdcddeb);
  static const navigationHoverDark = Color(0xff171721);
  static const navigationSelectedLight = Color(0xffd9dbfc);
  static const navigationSelected = Color(0xff221d51);
  static const navigationBorderLight = Color(0xffd2d3e1);
  static const navigationBorderDark = Color(0xff1f1e29);
  static const navigationTextLight = Color(0xff171721);
  static const navigationTextDark = Color(0xffeff0ff);
  static const navigationTextMutedLight = Color(0xff33343f);
  static const navigationTextMutedDark = Color(0xffc8c9d7);

  // Composer/Input Panel Tokens
  static const composerBackgroundDark = Color(0xff1f1e29);
  static const composerBackgroundLight = Color(0xfffbfbff);

  // Composer mode rail (Message / Ask AI switch strip): L 93% / 24%.
  static const composerRailLight = Color(0xffe6e7f5);
  static const composerRailDark = Color(0xff10101a);

  // Own Message Background Token (matches composer input area)
  static const ownMessageBackgroundDark = composerBackgroundDark;
  static const ownMessageBackgroundLight = composerBackgroundLight;

  // Contextual Getters
  static Color primaryForeground(bool isDark) =>
      isDark ? primaryForegroundDark : primaryForegroundLight;
  static Color primarySoftColor(bool isDark) =>
      isDark ? primarySoftDark : primarySoft;
  static Color canvas(bool isDark) => isDark ? canvasDark : canvasLight;
  static Color surface(bool isDark) => isDark ? surfaceDark : surfaceLight;
  static Color surfaceHover(bool isDark) =>
      isDark ? surfaceHoverDark : surfaceHoverLight;
  static Color border(bool isDark) => isDark ? borderDark : borderLight;
  static Color textPrimary(bool isDark) =>
      isDark ? textPrimaryDark : textPrimaryLight;
  static Color textSecondary(bool isDark) =>
      isDark ? textSecondaryDark : textSecondaryLight;
  static Color codeBackground(bool isDark) =>
      isDark ? codeBackgroundDark : codeBackgroundLight;
  static Color navigationBackground(bool isDark) =>
      isDark ? navigationBackgroundDark : navigationBackgroundLight;
  static Color navigationRaised(bool isDark) =>
      isDark ? navigationRaisedDark : navigationRaisedLight;
  static Color navigationHover(bool isDark) =>
      isDark ? navigationHoverDark : navigationHoverLight;
  static Color navigationBorder(bool isDark) =>
      isDark ? navigationBorderDark : navigationBorderLight;
  static Color navigationSelectedColor(bool isDark) =>
      isDark ? navigationSelected : navigationSelectedLight;
  static Color navigationText(bool isDark) =>
      isDark ? navigationTextDark : navigationTextLight;
  static Color navigationTextMuted(bool isDark) =>
      isDark ? navigationTextMutedDark : navigationTextMutedLight;
  static Color composerBackground(bool isDark) =>
      isDark ? composerBackgroundDark : composerBackgroundLight;
  static Color composerRail(bool isDark) =>
      isDark ? composerRailDark : composerRailLight;
  static Color ownMessageBackground(bool isDark) =>
      isDark ? ownMessageBackgroundDark : ownMessageBackgroundLight;

  // Semantic Status Colors
  static const success = Color(0xff22c55e);
  static const successSoftLight = Color(0xffd4f1d8);
  static const successSoftDark = Color(0xff042f12);

  static const warning = Color(0xfff59e0b);
  static const warningSoftLight = Color(0xfffce3c8);
  static const warningSoftDark = Color(0xff3b2000);

  static const error = Color(0xffef4444);
  static const errorSoftLight = Color(0xffffe0dc);
  static const errorSoftDark = Color(0xff431514);

  static const info = Color(0xff3b82f6);
  static const infoSoftLight = Color(0xffdbe9ff);
  static const infoSoftDark = Color(0xff112548);

  static const neutral = Color(0xff999aa8);
  static const neutralSoftLight = Color(0xffdcddeb);
  static const neutralSoftDark = Color(0xff242530);

  // Status colors for text and icons on light surfaces (WCAG AA >= 4.5 on
  // white). The base status colors stay for dots, fills, and dark mode.
  // Status and neutral text share one OKLCH lightness per theme on the 3%
  // ladder: L 51% light (base 27% + 8 steps), L 72% dark (base 96% - 8 steps).
  static const successTextLight = Color(0xff0e7b38);
  static const warningTextLight = Color(0xffa14904);
  static const errorTextLight = Color(0xffbb1e1e);
  static const infoTextLight = Color(0xff2355e0);
  static const successTextDark = Color(0xff20c45d);
  static const warningTextDark = Color(0xffe48f00);
  static const errorTextDark = Color(0xfffe726b);
  static const infoTextDark = Color(0xff66a3ff);
  static const neutralTextDark = Color(0xffa2a3b1);
  static const neutralTextLight = Color(0xff525460);

  // Status Contextual Getters
  static Color successText(bool isDark) =>
      isDark ? successTextDark : successTextLight;
  static Color warningText(bool isDark) =>
      isDark ? warningTextDark : warningTextLight;
  static Color errorText(bool isDark) =>
      isDark ? errorTextDark : errorTextLight;
  static Color infoText(bool isDark) => isDark ? infoTextDark : infoTextLight;
  static Color neutralText(bool isDark) =>
      isDark ? neutralTextDark : neutralTextLight;
  static Color successSoft(bool isDark) =>
      isDark ? successSoftDark : successSoftLight;
  static Color warningSoft(bool isDark) =>
      isDark ? warningSoftDark : warningSoftLight;
  static Color errorSoft(bool isDark) =>
      isDark ? errorSoftDark : errorSoftLight;
  static Color infoSoft(bool isDark) => isDark ? infoSoftDark : infoSoftLight;
  static Color neutralSoft(bool isDark) =>
      isDark ? neutralSoftDark : neutralSoftLight;
}
