import 'package:conclave_design/conclave_design.dart';
import 'package:flutter/material.dart';

/// Profile Lab styling and visual identity.
abstract final class ProfileLabTheme {
  static const interactionText = Color(0xFFA5B4FC);
  static const secondaryText = Color(0xFFCBD5E1);
  static const borderColor = Color(0xFF475569);
  static const primaryAccent = Color(0xFF6366F1); // Indigo
  static const darkBackground = Color(0xFF0F172A); // Slate 900
  static const darkSurface = Color(0xFF1E293B); // Slate 800
  static const darkCard = Color(0xFF334155); // Slate 700
  static const passColor = Color(0xFF10B981); // Emerald
  static const warnColor = Color(0xFFF59E0B); // Amber
  static const failColor = Color(0xFFF87171); // Rose/Red

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
              foregroundColor: const Color(0xFFA5B4FC))),
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
