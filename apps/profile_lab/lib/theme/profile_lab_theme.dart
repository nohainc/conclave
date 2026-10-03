import 'package:flutter/material.dart';

/// Profile Lab styling and visual identity.
abstract final class ProfileLabTheme {
  static const primaryAccent = Color(0xFF6366F1); // Indigo
  static const darkBackground = Color(0xFF0F172A); // Slate 900
  static const darkSurface = Color(0xFF1E293B); // Slate 800
  static const darkCard = Color(0xFF334155); // Slate 700
  static const passColor = Color(0xFF10B981); // Emerald
  static const warnColor = Color(0xFFF59E0B); // Amber
  static const failColor = Color(0xFFEF4444); // Rose/Red

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: darkBackground,
      colorScheme: const ColorScheme.dark(
        primary: primaryAccent,
        surface: darkSurface,
        onSurface: Colors.white,
      ),
      cardTheme: const CardThemeData(
        color: darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide(color: Color(0xFF334155), width: 1),
        ),
      ),
      fontFamily: '-apple-system',
      textTheme: const TextTheme(
        headlineMedium:
            TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        titleLarge: TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.3),
        titleMedium: TextStyle(fontWeight: FontWeight.w600),
        bodyMedium: TextStyle(fontSize: 13, height: 1.4),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
      ),
    );
  }

  static TextStyle get monoStyle => const TextStyle(
        fontFamily: 'Menlo',
        fontSize: 12,
        height: 1.5,
      );
}
