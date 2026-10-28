@TestOn('browser')
library;

import 'package:syntila_app/src/platform/theme_preference.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

void main() {
  test('browser preference restores the latest choice from local storage', () {
    const key = 'syntila-theme-v1';
    final previous = web.window.localStorage.getItem(key);
    addTearDown(() {
      if (previous == null) {
        web.window.localStorage.removeItem(key);
      } else {
        web.window.localStorage.setItem(key, previous);
      }
    });
    web.window.localStorage.removeItem(key);
    expect(createThemePreference().load(), ThemeMode.system);
    for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system]) {
      createThemePreference().save(mode);
      expect(createThemePreference().load(), mode);
    }
    web.window.localStorage.setItem(key, 'unknown');
    expect(createThemePreference().load(), ThemeMode.system);
  });
}
