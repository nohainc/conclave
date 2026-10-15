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
  static const borderLight = Color(0xffd2d1ca);
  static const textPrimaryLight = Color(0xff20202a);
  static const textSecondaryLight = Color(0xff62626f);
  static const codeBackgroundLight = Color(0xfff0eee8);

  // Dark Mode Surfaces & Inks
  static const canvasDark = Color(0xff1b1a24);
  static const surfaceDark = Color(0xff24222e);
  static const surfaceHoverDark = Color(0xff343142);
  static const borderDark = Color(0xff403d50);
  static const textPrimaryDark = Color(0xfff4f4f6);
  static const textSecondaryDark = Color(0xffaaa7b8);
  static const codeBackgroundDark = Color(0xff15151d);

  // Navigation Tokens
  static const navigationBackgroundLight = Color(0xffffffff);
  static const navigationBackgroundDark = Color(0xff121119);
  static const navigationRaisedLight = Color(0xfff8f7f3);
  static const navigationRaisedDark = Color(0xff121119);
  static const navigationHoverLight = Color(0xfff1efe8);
  static const navigationHoverDark = Color(0xff1d1c28);
  static const navigationSelected = Color(0xff302b4d);
  static const navigationBorderLight = Color(0xffd2d1ca);
  static const navigationBorderDark = Color(0xff1f1e2a);
  static const navigationTextLight = Color(0xff20202a);
  static const navigationTextDark = Color(0xfff4f4f6);
  static const navigationTextMutedLight = Color(0xff62626f);
  static const navigationTextMutedDark = Color(0xffaaa7b8);

  // Composer/Input Panel Tokens
  static const composerBackgroundDark = Color(0xff2c2939);
  static const composerBackgroundLight = Color(0xfffaf9f5);

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
  static Color navigationText(bool isDark) =>
      isDark ? navigationTextDark : navigationTextLight;
  static Color navigationTextMuted(bool isDark) =>
      isDark ? navigationTextMutedDark : navigationTextMutedLight;
  static Color composerBackground(bool isDark) =>
      isDark ? composerBackgroundDark : composerBackgroundLight;
  static Color ownMessageBackground(bool isDark) =>
      isDark ? ownMessageBackgroundDark : ownMessageBackgroundLight;

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

  // Status colors for text and icons on light surfaces (WCAG AA >= 4.5 on
  // white). The base status colors stay for dots, fills, and dark mode.
  static const successTextLight = Color(0xff15803d);
  static const warningTextLight = Color(0xffb45309);
  static const errorTextLight = Color(0xffb91c1c);
  static const infoTextLight = Color(0xff1d4ed8);
  static const neutralTextLight = Color(0xff62626f);

  // Status Contextual Getters
  static Color successText(bool isDark) => isDark ? success : successTextLight;
  static Color warningText(bool isDark) => isDark ? warning : warningTextLight;
  static Color errorText(bool isDark) => isDark ? error : errorTextLight;
  static Color infoText(bool isDark) => isDark ? info : infoTextLight;
  static Color neutralText(bool isDark) => isDark ? neutral : neutralTextLight;
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
