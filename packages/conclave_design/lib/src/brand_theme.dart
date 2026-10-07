import 'package:flutter/material.dart';

import 'colors.dart';
import 'radius.dart';
import 'typography.dart';
import 'brand_assets.dart';

/// Shared Conclave AX theme system and brand container.
abstract final class ConclaveBrand {
  // Brand Accents
  static const accent = ConclaveColors.primary;
  static const accentDark = ConclaveColors.primaryPressed;
  static const accentWash = ConclaveColors.primarySoft;
  static const accentWashDark = ConclaveColors.primarySoftDark;
  static const navigationSelection = ConclaveColors.navigationSelected;

  // Light Palette
  static const lightInk = ConclaveColors.textPrimaryLight;
  static const lightInkMuted = ConclaveColors.textSecondaryLight;
  static const lightPaper = ConclaveColors.canvasLight;
  static const lightSurface = ConclaveColors.surfaceLight;
  static const lightSurfaceHover = ConclaveColors.surfaceHoverLight;
  static const lightLine = ConclaveColors.borderLight;
  static const lightCodeBackground = ConclaveColors.codeBackgroundLight;

  // Dark Palette
  static const darkInk = ConclaveColors.textPrimaryDark;
  static const darkInkMuted = ConclaveColors.textSecondaryDark;
  static const darkPaper = ConclaveColors.canvasDark;
  static const darkSurface = ConclaveColors.surfaceDark;
  static const darkSurfaceHover = ConclaveColors.surfaceHoverDark;
  static const darkLine = ConclaveColors.borderDark;
  static const darkCodeBackground = ConclaveColors.codeBackgroundDark;

  // Semantic Status Colors
  static const success = ConclaveColors.success;
  static const successWash = ConclaveColors.successSoftLight;
  static const successWashDark = ConclaveColors.successSoftDark;

  static const warning = ConclaveColors.warning;
  static const warningWash = ConclaveColors.warningSoftLight;
  static const warningWashDark = ConclaveColors.warningSoftDark;

  static const error = ConclaveColors.error;
  static const errorWash = ConclaveColors.errorSoftLight;
  static const errorWashDark = ConclaveColors.errorSoftDark;

  static const info = ConclaveColors.info;
  static const infoWash = ConclaveColors.infoSoftLight;
  static const infoWashDark = ConclaveColors.infoSoftDark;

  static const neutral = ConclaveColors.neutral;
  static const neutralWash = ConclaveColors.neutralSoftLight;
  static const neutralWashDark = ConclaveColors.neutralSoftDark;

  // Legacy compatibility getters for existing code
  static const ink = lightInk;
  static const paper = lightPaper;
  static const surface = lightSurface;
  static const line = lightLine;
  static const navigation = ConclaveColors.textPrimaryLight;

  static const brandMark = BoxDecoration(
    color: accent,
    borderRadius: BorderRadius.all(Radius.circular(10)),
  );

  static const logoAsset = ConclaveBrandAssets.logoPng1024;

  static Widget logoMark({
    double size = 28,
    BorderRadius? borderRadius,
    BoxFit fit = BoxFit.contain,
  }) =>
      ConclaveBrandAssets.logoMark(
        size: size,
        borderRadius: borderRadius,
        fit: fit,
      );

  // Responsive Breakpoints
  static const double desktopBreakpoint = 600.0;
  static const double tabletBreakpoint = 600.0;

  static bool isDesktop(double width) => width >= desktopBreakpoint;
  static bool isTablet(double width) => width < desktopBreakpoint;
  static bool isMobile(double width) => width < desktopBreakpoint;

  /// Builds the canonical light [ThemeData] for Conclave AX.
  static ThemeData lightTheme() {
    const colorScheme = ColorScheme.light(
      primary: ConclaveColors.primary,
      primaryContainer: ConclaveColors.primarySoft,
      secondary: ConclaveColors.primaryPressed,
      surface: ConclaveColors.surfaceLight,
      error: ConclaveColors.error,
      onPrimary: Colors.white,
      onPrimaryContainer: ConclaveColors.primaryPressed,
      onSurface: ConclaveColors.textPrimaryLight,
      onError: Colors.white,
      outline: ConclaveColors.borderLight,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: ConclaveColors.canvasLight,
      cardColor: ConclaveColors.surfaceLight,
      dividerColor: ConclaveColors.borderLight,
      fontFamily: ConclaveTypography.fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: ConclaveColors.surfaceLight,
        foregroundColor: ConclaveColors.textPrimaryLight,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: ConclaveColors.surfaceLight,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: ConclaveColors.borderLight),
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ConclaveColors.surfaceLight,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
          borderSide: const BorderSide(color: ConclaveColors.borderLight),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
          borderSide: const BorderSide(color: ConclaveColors.borderLight),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
          borderSide:
              const BorderSide(color: ConclaveColors.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(ConclaveColors.textPrimaryLight),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(
          ConclaveColors.borderLight, ConclaveColors.primaryForegroundLight),
      textButtonTheme: _textButtonTheme(ConclaveColors.primaryForegroundLight),
      chipTheme: _chipTheme(
          ConclaveColors.surfaceHoverLight, ConclaveColors.textPrimaryLight),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ConclaveColors.textPrimaryLight,
        contentTextStyle: const TextStyle(
          color: ConclaveColors.textPrimaryDark,
          fontSize: 13,
          fontFamily: ConclaveTypography.fontFamily,
        ),
        actionTextColor: ConclaveColors.primaryForegroundDark,
        disabledActionTextColor: ConclaveColors.textSecondaryLight,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ConclaveRadius.md)),
      ),
    );
  }

  /// Builds the canonical dark [ThemeData] for Conclave AX.
  static ThemeData darkTheme() {
    const colorScheme = ColorScheme.dark(
      primary: ConclaveColors.primary,
      primaryContainer: ConclaveColors.primarySoftDark,
      secondary: ConclaveColors.primaryPressed,
      surface: ConclaveColors.surfaceDark,
      error: ConclaveColors.error,
      onPrimary: Colors.white,
      onPrimaryContainer: Colors.white,
      onSurface: ConclaveColors.textPrimaryDark,
      onError: Colors.white,
      outline: ConclaveColors.borderDark,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: ConclaveColors.canvasDark,
      cardColor: ConclaveColors.surfaceDark,
      dividerColor: ConclaveColors.borderDark,
      fontFamily: ConclaveTypography.fontFamily,
      appBarTheme: const AppBarTheme(
        backgroundColor: ConclaveColors.surfaceDark,
        foregroundColor: ConclaveColors.textPrimaryDark,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: ConclaveColors.surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: ConclaveColors.borderDark),
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: ConclaveColors.surfaceDark,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
          borderSide: const BorderSide(color: ConclaveColors.borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
          borderSide: const BorderSide(color: ConclaveColors.borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
          borderSide:
              const BorderSide(color: ConclaveColors.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(ConclaveColors.textPrimaryDark),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(
          ConclaveColors.borderDark, ConclaveColors.primaryForegroundDark),
      textButtonTheme: _textButtonTheme(ConclaveColors.primaryForegroundDark),
      chipTheme: _chipTheme(
          ConclaveColors.surfaceHoverDark, ConclaveColors.textPrimaryDark),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: ConclaveColors.surfaceHoverDark,
        contentTextStyle: const TextStyle(
          color: ConclaveColors.textPrimaryDark,
          fontSize: 13,
          fontFamily: ConclaveTypography.fontFamily,
        ),
        actionTextColor: ConclaveColors.primaryForegroundDark,
        disabledActionTextColor: ConclaveColors.textSecondaryDark,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: ConclaveColors.borderDark),
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
        ),
      ),
    );
  }

  static TextTheme _textTheme(Color foreground) => TextTheme(
        headlineMedium: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w700,
          fontSize: 24,
          letterSpacing: -0.5,
        ),
        titleLarge: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w700,
          fontSize: 20,
          letterSpacing: -0.3,
        ),
        titleMedium: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w600,
          fontSize: 16,
        ),
        titleSmall: TextStyle(
          color: foreground,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
        bodyLarge: TextStyle(
          color: foreground,
          fontSize: 14,
          height: 1.45,
        ),
        bodyMedium: TextStyle(
          color: foreground,
          fontSize: 13.5,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          color: foreground,
          fontSize: 12,
          height: 1.35,
        ),
        labelSmall: TextStyle(
          color: foreground,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
        ),
      );

  static FilledButtonThemeData _filledButtonTheme() => FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ConclaveColors.primary,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.md)),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(Color border,
          [Color? foreground]) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground ?? ConclaveColors.primary,
          side: BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.md)),
        ),
      );

  static TextButtonThemeData _textButtonTheme([Color? foreground]) =>
      TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: foreground ?? ConclaveColors.primary,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.sm)),
        ),
      );

  static ChipThemeData _chipTheme(Color surface, Color foreground) =>
      ChipThemeData(
        backgroundColor: surface,
        labelStyle: TextStyle(color: foreground, fontSize: 12),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ConclaveRadius.pill)),
      );
}
