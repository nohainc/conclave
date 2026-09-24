import 'package:flutter/material.dart';

/// Shared Conclave AX design tokens and theme system.
abstract final class ConclaveBrand {
  // Brand Accents
  static const accent = Color(0xff5e4bd8);
  static const accentDark = Color(0xff4937bd);
  static const accentWash = Color(0xffdedcf4);
  static const accentWashDark = Color(0xff231d47);

  // Light Palette
  static const lightInk = Color(0xff20202a);
  static const lightInkMuted = Color(0xff6e6e7c);
  static const lightPaper = Color(0xfff8f7f3);
  static const lightSurface = Color(0xffffffff);
  static const lightSurfaceHover = Color(0xfff1efe8);
  static const lightLine = Color(0xffdfded8);
  static const lightCodeBackground = Color(0xfff0eee8);

  // Dark Palette
  static const darkInk = Color(0xfff4f4f6);
  static const darkInkMuted = Color(0xff9e9eaf);
  static const darkPaper = Color(0xff121217);
  static const darkSurface = Color(0xff1a1a22);
  static const darkSurfaceHover = Color(0xff24242f);
  static const darkLine = Color(0xff2e2e3a);
  static const darkCodeBackground = Color(0xff15151d);

  // Semantic Status Colors
  static const success = Color(0xff22c55e);
  static const successWash = Color(0xffdcfce7);
  static const successWashDark = Color(0xff14532d);

  static const warning = Color(0xfff59e0b);
  static const warningWash = Color(0xfffef3c7);
  static const warningWashDark = Color(0xff78350f);

  static const error = Color(0xffef4444);
  static const errorWash = Color(0xfffee2e2);
  static const errorWashDark = Color(0xff7f1d1d);

  static const info = Color(0xff3b82f6);
  static const infoWash = Color(0xffdbeafe);
  static const infoWashDark = Color(0xff1e3a8a);

  // Legacy compatibility getters for existing code
  static const ink = lightInk;
  static const paper = lightPaper;
  static const surface = lightSurface;
  static const line = lightLine;
  static const navigation = Color(0xff20202a);

  static const brandMark = BoxDecoration(
    color: accent,
    borderRadius: BorderRadius.all(Radius.circular(10)),
  );

  static const logoAsset = 'assets/branding/conclave_logo.png';

  /// Renders the official Conclave AX logo mark.
  /// Falls back gracefully to the styled vector mark if asset is not loaded.
  static Widget logoMark({
    double size = 28,
    BorderRadius? borderRadius,
    BoxFit fit = BoxFit.contain,
  }) {
    return ClipRRect(
      borderRadius: borderRadius ?? BorderRadius.circular(size * (10 / 28)),
      child: Image.asset(
        logoAsset,
        width: size,
        height: size,
        fit: fit,
        errorBuilder: (context, error, stackTrace) => Container(
          width: size,
          height: size,
          decoration: brandMark,
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
      ),
    );
  }

  // Responsive Breakpoints (2 modes)
  // Desktop >= 600
  // Tablet < 600
  static const double desktopBreakpoint = 600.0;
  static const double tabletBreakpoint = 600.0;

  static bool isDesktop(double width) => width >= desktopBreakpoint;
  static bool isTablet(double width) => width < desktopBreakpoint;
  static bool isMobile(double width) => width < desktopBreakpoint;

  /// Builds the light [ThemeData] for Conclave AX.
  static ThemeData lightTheme() {
    const colorScheme = ColorScheme.light(
      primary: accent,
      primaryContainer: accentWash,
      secondary: accentDark,
      surface: lightSurface,
      error: error,
      onPrimary: Colors.white,
      onPrimaryContainer: accentDark,
      onSurface: lightInk,
      onError: Colors.white,
      outline: lightLine,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: lightPaper,
      cardColor: lightSurface,
      dividerColor: lightLine,
      fontFamily: 'Inter',
      appBarTheme: const AppBarTheme(
        backgroundColor: lightSurface,
        foregroundColor: lightInk,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: lightLine),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: lightSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: lightLine),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: lightLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(lightInk),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(lightLine),
      chipTheme: _chipTheme(lightSurfaceHover, lightInk),
    );
  }

  /// Builds the dark [ThemeData] for Conclave AX.
  static ThemeData darkTheme() {
    const colorScheme = ColorScheme.dark(
      primary: accent,
      primaryContainer: accentWashDark,
      secondary: accentDark,
      surface: darkSurface,
      error: error,
      onPrimary: Colors.white,
      onPrimaryContainer: Colors.white,
      onSurface: darkInk,
      onError: Colors.white,
      outline: darkLine,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: darkPaper,
      cardColor: darkSurface,
      dividerColor: darkLine,
      fontFamily: 'Inter',
      appBarTheme: const AppBarTheme(
        backgroundColor: darkSurface,
        foregroundColor: darkInk,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: darkLine),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: darkLine),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: darkLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
      textTheme: _textTheme(darkInk),
      filledButtonTheme: _filledButtonTheme(),
      outlinedButtonTheme: _outlinedButtonTheme(darkLine),
      chipTheme: _chipTheme(darkSurfaceHover, darkInk),
    );
  }

  static TextTheme _textTheme(Color foreground) => TextTheme(
        bodyLarge: TextStyle(color: foreground, height: 1.4),
        bodyMedium: TextStyle(color: foreground, height: 1.4),
        titleMedium: TextStyle(color: foreground, fontWeight: FontWeight.w700),
      );

  static FilledButtonThemeData _filledButtonTheme() => FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ConclaveRadius.md)),
        ),
      );

  static OutlinedButtonThemeData _outlinedButtonTheme(Color border) =>
      OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accent,
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

/// Spacing scale constants
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

/// Border radius constants
abstract final class ConclaveRadius {
  static const double sm = 6.0;
  static const double md = 10.0;
  static const double lg = 14.0;
  static const double xl = 20.0;
  static const double pill = 999.0;
}
