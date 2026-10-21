import 'package:flutter/material.dart';

import 'theme_preference_stub.dart'
    if (dart.library.js_interop) 'theme_preference_web.dart' as platform;

/// Device-local appearance preference, independent of account and Cloud state.
class ThemePreference {
  ThemePreference({required this.read, required this.write});

  final String? Function() read;
  final void Function(String value) write;

  ThemeMode load() {
    try {
      return switch (read()) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    } catch (_) {
      return ThemeMode.system;
    }
  }

  void save(ThemeMode mode) {
    try {
      write(mode.name);
    } catch (_) {
      // Storage can be unavailable; the current session still keeps its choice.
    }
  }
}

ThemePreference createThemePreference() => platform.createThemePreference();
