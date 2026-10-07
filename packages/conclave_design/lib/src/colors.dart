import 'package:flutter/material.dart';

/// Semantic brand colors and design tokens for Conclave AX.
abstract final class ConclaveColors {
  // Brand Core
  static const primary = Color(0xff5e4bd8);
  static const primaryPressed = Color(0xff4937bd);
  static const primaryForegroundLight = Color(0xff5e4bd8);
  static const primaryForegroundDark = Color(0xffb8a9fe);
  static const primarySoft = Color(0xffdedcf4);
  static const primarySoftDark = Color(0xff231d47);

  // Light Mode Surfaces & Inks
  static const canvasLight = Color(0xfff8f7f3);
  static const surfaceLight = Color(0xffffffff);
  static const surfaceHoverLight = Color(0xfff1efe8);
  static const borderLight = Color(0xffdfded8);
  static const textPrimaryLight = Color(0xff20202a);
  static const textSecondaryLight = Color(0xff6e6e7c);
  static const codeBackgroundLight = Color(0xfff0eee8);

  // Dark Mode Surfaces & Inks
  static const canvasDark = Color(0xff121217);
  static const surfaceDark = Color(0xff1a1a22);
  static const surfaceHoverDark = Color(0xff24242f);
  static const borderDark = Color(0xff2e2e3a);
  static const textPrimaryDark = Color(0xfff4f4f6);
  static const textSecondaryDark = Color(0xff9e9eaf);
  static const codeBackgroundDark = Color(0xff15151d);

  // Navigation Tokens
  static const navigationBackgroundLight = Color(0xffffffff);
  static const navigationBackgroundDark = Color(0xff20202a);
  static const navigationRaisedLight = Color(0xfff8f7f3);
  static const navigationRaisedDark = Color(0xff20202a);
  static const navigationHoverLight = Color(0xfff1efe8);
  static const navigationHoverDark = Color(0xff24242f);
  static const navigationSelected = Color(0xff302d4b);
  static const navigationBorderLight = Color(0xffdfded8);
  static const navigationBorderDark = Color(0xff2e2e3a);
  static const navigationTextLight = Color(0xff20202a);
  static const navigationTextDark = Color(0xfff4f4f6);
  static const navigationTextMutedLight = Color(0xff6e6e7c);
  static const navigationTextMutedDark = Color(0xff9e9eaf);

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
  static Color navigationText(bool isDark) =>
      isDark ? navigationTextDark : navigationTextLight;
  static Color navigationTextMuted(bool isDark) =>
      isDark ? navigationTextMutedDark : navigationTextMutedLight;

  // Semantic Status Colors
  static const success = Color(0xff22c55e);
  static const successSoftLight = Color(0xffdcfce7);
  static const successSoftDark = Color(0xff14532d);

  static const warning = Color(0xfff59e0b);
  static const warningSoftLight = Color(0xfffef3c7);
  static const warningSoftDark = Color(0xff78350f);

  static const error = Color(0xffef4444);
  static const errorSoftLight = Color(0xfffee2e2);
  static const errorSoftDark = Color(0xff7f1d1d);

  static const info = Color(0xff3b82f6);
  static const infoSoftLight = Color(0xffdbeafe);
  static const infoSoftDark = Color(0xff1e3a8a);

  static const neutral = Color(0xff9e9eaf);
  static const neutralSoftLight = Color(0xffe5e5eb);
  static const neutralSoftDark = Color(0xff2a2a35);

  // Status Contextual Getters
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
