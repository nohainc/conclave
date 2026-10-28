import 'package:flutter/material.dart';

/// Semantic brand colors and design tokens for Syntila.
abstract final class SyntilaColors {
  // Brand Core
  static const primary = Color(0xff0759d1);
  static const primaryPressed = Color(0xff044cb6);
  static const primaryForegroundLight = Color(0xff0759d1);
  static const primaryForegroundDark = Color(0xffb8d2fd);
  static const primarySoft = Color(0xffcddffd);
  static const primarySoftDark = Color(0xff0a244f);
  static const primaryRunningIndicator = Color(0xff5e93e1);

  // Focused input field: border and floating label. Mirrored across themes
  // like the text ramp (light + dark lightness = 117); the label sits 6
  // points further from the field background than the border.
  static const focusBorderLight = Color(0xff0759d1);
  static const focusBorderDark = Color(0xff5893f6);
  static const focusLabelLight = Color(0xff044ab1);
  static const focusLabelDark = Color(0xff76a8f9);
  static Color focusBorder(bool isDark) =>
      isDark ? focusBorderDark : focusBorderLight;
  static Color focusLabel(bool isDark) =>
      isDark ? focusLabelDark : focusLabelLight;

  // Light Mode Surfaces & Inks
  static const canvasLight = Color(0xfff1f2f4);
  static const surfaceLight = Color(0xfffbfcfd);
  static const surfaceHoverLight = Color(0xffe7e8ea);
  static const borderLight = Color(0xffd3d5d7);
  static const textPrimaryLight = Color(0xff17181a);
  static const textSecondaryLight = Color(0xff434547);
  static const codeBackgroundLight = Color(0xffe7e8ea);

  // Dark Mode Surfaces & Inks
  static const canvasDark = Color(0xff17181a);
  static const surfaceDark = Color(0xff1e2021);
  static const surfaceHoverDark = Color(0xff252628);
  static const borderDark = Color(0xff2d2e30);
  static const textPrimaryDark = Color(0xfff1f2f4);
  static const textSecondaryDark = Color(0xffb6b8ba);
  static const codeBackgroundDark = Color(0xff111213);

  // Navigation Tokens
  static const navigationBackgroundLight = Color(0xffe7e8ea);
  static const navigationBackgroundDark = Color(0xff111213);
  static const navigationRaisedLight = Color(0xfff1f2f4);
  static const navigationRaisedDark = Color(0xff111213);
  static const navigationHoverLight = Color(0xffdddfe1);
  static const navigationHoverDark = Color(0xff17181a);
  static const navigationSelectedLight = Color(0xffd3d5d7);
  static const navigationSelected = Color(0xff252628);
  static const navigationBorderLight = Color(0xffd3d5d7);
  static const navigationBorderDark = Color(0xff1e2021);
  static const navigationTextLight = Color(0xff17181a);
  static const navigationTextDark = Color(0xfff1f2f4);
  static const navigationTextMutedLight = Color(0xff434547);
  static const navigationTextMutedDark = Color(0xffb6b8ba);

  // Composer/Input Panel Tokens
  static const composerBackgroundDark = Color(0xff1e2021);
  static const composerBackgroundLight = Color(0xfffbfcfd);

  // Composer mode rail (Message / Ask AI switch strip): L 93% / 24%.
  static const composerRailLight = Color(0xffe7e8ea);
  static const composerRailDark = Color(0xff111213);

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

  static const neutral = Color(0xff999b9d);
  static const neutralSoftLight = Color(0xffdddfe1);
  static const neutralSoftDark = Color(0xff252628);

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
  static const neutralTextDark = Color(0xffa3a5a7);
  static const neutralTextLight = Color(0xff535557);

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

  // Code Syntax Highlighting Tokens
  static const syntaxKeywordLight = Color(0xff6d28d9);
  static const syntaxKeywordDark = Color(0xffc4b5fd);
  static const syntaxStringLight = Color(0xff166534);
  static const syntaxStringDark = Color(0xff86efac);
  static const syntaxNumberLight = Color(0xff9a3412);
  static const syntaxNumberDark = Color(0xfffdba74);
  static const syntaxTitleLight = Color(0xff1d4ed8);
  static const syntaxTitleDark = Color(0xff93c5fd);
  static const syntaxBracketDark = Color(0xffd6b675);

  static Color syntaxKeyword(bool isDark) =>
      isDark ? syntaxKeywordDark : syntaxKeywordLight;
  static Color syntaxString(bool isDark) =>
      isDark ? syntaxStringDark : syntaxStringLight;
  static Color syntaxNumber(bool isDark) =>
      isDark ? syntaxNumberDark : syntaxNumberLight;
  static Color syntaxTitle(bool isDark) =>
      isDark ? syntaxTitleDark : syntaxTitleLight;
}
