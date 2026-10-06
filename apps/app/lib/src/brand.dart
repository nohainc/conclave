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
  static const navigationBackgroundDark = Color(0xff1a1a22);
  static const navigationHoverLight = Color(0xfff1efe8);
  static const navigationHoverDark = Color(0xff24242f);
  static const navigationSelected = Color(0xff302d4b);
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
  static Color navigationHover(bool isDark) =>
      isDark ? navigationHoverDark : navigationHoverLight;
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

  // Status Contextual Getters
  static Color successSoft(bool isDark) =>
      isDark ? successSoftDark : successSoftLight;
  static Color warningSoft(bool isDark) =>
      isDark ? warningSoftDark : warningSoftLight;
  static Color errorSoft(bool isDark) =>
      isDark ? errorSoftDark : errorSoftLight;
  static Color infoSoft(bool isDark) => isDark ? infoSoftDark : infoSoftLight;
}

/// Typography scale and font families for Conclave AX.
abstract final class ConclaveTypography {
  static const fontFamily = 'Inter';
  static const fontFamilyMono = 'JetBrains Mono';

  static const h1 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.02,
    height: 1.25,
  );

  static const h2 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 18,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.01,
    height: 1.3,
  );

  static const h3 = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    height: 1.35,
  );

  static const body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    height: 1.4,
  );

  static const bodySmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );

  static const mono = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.4,
  );

  static const monoSmall = TextStyle(
    fontFamily: fontFamilyMono,
    fontSize: 11,
    fontWeight: FontWeight.w400,
    height: 1.3,
  );
}

/// Spacing scale constants for Conclave AX (4/8px grid system).
abstract final class ConclaveSpacing {
  static const double xxs = 2.0;
  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 24.0;
  static const double xxl = 32.0;
  static const double xxxl = 48.0;
}

/// Border radius constants for Conclave AX.
abstract final class ConclaveRadius {
  static const double xs = 4.0;
  static const double sm = 6.0;
  static const double md = 10.0;
  static const double lg = 14.0;
  static const double xl = 20.0;
  static const double pill = 999.0;

  static const radiusXs = BorderRadius.all(Radius.circular(xs));
  static const radiusSm = BorderRadius.all(Radius.circular(sm));
  static const radiusMd = BorderRadius.all(Radius.circular(md));
  static const radiusLg = BorderRadius.all(Radius.circular(lg));
  static const radiusXl = BorderRadius.all(Radius.circular(xl));
  static const radiusPill = BorderRadius.all(Radius.circular(pill));
}

/// Canonical brand asset identifiers and rendering helpers.
abstract final class ConclaveBrandAssets {
  static const markSvg = 'assets/branding/conclave_mark.svg';
  static const markDarkSvg = 'assets/branding/conclave_mark_dark.svg';
  static const markMonochromeSvg = 'assets/branding/conclave_mark_monochrome.svg';
  static const markTwotoneSvg = 'assets/branding/conclave_mark_twotone.svg';
  static const wordmarkSvg = 'assets/branding/conclave_wordmark.svg';
  static const wordmarkDarkSvg = 'assets/branding/conclave_wordmark_dark.svg';
  static const logoMasterSvg = 'assets/branding/conclave_logo.svg';

  static const logoPng1024 = 'assets/branding/conclave_logo.png';
  static const logoPng512 = 'assets/branding/conclave_logo_512.png';
  static const logoPng192 = 'assets/branding/conclave_logo_192.png';
  static const logoPng128 = 'assets/branding/conclave_logo_128.png';
  static const logoPng64 = 'assets/branding/conclave_logo_64.png';
  static const logoPng32 = 'assets/branding/conclave_logo_32.png';

  /// Renders the official Conclave AX logo mark.
  static Widget logoMark({
    double size = 28,
    BorderRadius? borderRadius,
    BoxFit fit = BoxFit.contain,
  }) {
    final image = Image.asset(
      logoPng1024,
      width: size,
      height: size,
      fit: fit,
      errorBuilder: (context, error, stackTrace) => Container(
        width: size,
        height: size,
        decoration: const BoxDecoration(
          color: ConclaveColors.primary,
          borderRadius: BorderRadius.all(Radius.circular(10)),
        ),
        alignment: Alignment.center,
        child: Text(
          'C',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: size * 0.54,
          ),
        ),
      ),
    );
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius, child: image);
    }
    return image;
  }
}

/// Shared Conclave AX theme system and legacy adapter.
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

  /// Builds the light [ThemeData] for Conclave AX.
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
          borderSide: const BorderSide(color: ConclaveColors.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(ConclaveColors.textPrimaryLight),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(ConclaveColors.borderLight),
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

  /// Builds the dark [ThemeData] for Conclave AX.
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
          borderSide: const BorderSide(color: ConclaveColors.primary, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(ConclaveColors.textPrimaryDark),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(ConclaveColors.borderDark),
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
          side: const BorderSide(color: Color(0xff3e3e4f)),
          borderRadius: BorderRadius.circular(ConclaveRadius.md),
        ),
      ),
    );
  }

  static TextTheme _textTheme(Color foreground) => TextTheme(
        bodyLarge: TextStyle(color: foreground, height: 1.4),
        bodyMedium: TextStyle(color: foreground, height: 1.4),
        titleMedium: TextStyle(color: foreground, fontWeight: FontWeight.w700),
      );

  static FilledButtonThemeData _filledButtonTheme() => FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: ConclaveColors.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.md)),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(Color border) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ConclaveColors.primary,
          side: BorderSide(color: border),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.md)),
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
