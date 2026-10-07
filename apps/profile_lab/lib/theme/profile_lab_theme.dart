import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';

/// Profile Lab styling and visual identity.
abstract final class ProfileLabTheme {
  static const interactionText = ConclaveColors.primaryForegroundDark;
  static const secondaryText = ConclaveColors.textSecondaryDark;
  static const borderColor = ConclaveColors.borderDark;
  static const primaryAccent = ConclaveColors.primary;
  static const darkBackground = ConclaveColors.canvasDark;
  static const darkSurface = ConclaveColors.surfaceDark;
  static const darkCard = ConclaveColors.surfaceHoverDark;
  static const passColor = ConclaveColors.success;
  static const warnColor = ConclaveColors.warning;
  static const failColor = ConclaveColors.error;

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: primaryAccent,
        onPrimary: Colors.white,
        secondary: primaryAccent,
        onSecondary: Colors.white,
        surface: darkSurface,
        onSurface: Colors.white,
      ),
      visualDensity: VisualDensity.standard,
      filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
              minimumSize: const Size(48, 40),
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12))),
      elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
              backgroundColor: primaryAccent,
              foregroundColor: Colors.white,
              minimumSize: const Size(48, 40))),
      outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 40),
              foregroundColor: Colors.white,
              side: const BorderSide(color: borderColor))),
      textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
              minimumSize: const Size(48, 40),
              foregroundColor: interactionText)),
      iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(minimumSize: const Size(40, 40))),
      dataTableTheme: const DataTableThemeData(
          dataRowMinHeight: 48, dataRowMaxHeight: 64, headingRowHeight: 48),
      listTileTheme: const ListTileThemeData(
          selectedColor: Colors.white, minVerticalPadding: 12),
      dividerTheme: const DividerThemeData(color: borderColor),
      inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(), contentPadding: EdgeInsets.all(12)),
      cardTheme: const CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide(color: borderColor, width: 1),
        ),
      ),
      fontFamily: ConclaveTypography.fontFamily,
      textTheme: const TextTheme(
        headlineMedium:
            TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.3),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(fontSize: 13, height: 1.4),
        bodySmall: TextStyle(fontSize: 12, color: secondaryText),
      ),
    );
  }

  static TextStyle get monoStyle => ConclaveTypography.mono;
}
