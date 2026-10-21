import 'package:web/web.dart' as web;

import 'theme_preference.dart';

const _key = 'conclave-ax-theme-v1';

ThemePreference createThemePreference() => ThemePreference(
      read: () => web.window.localStorage.getItem(_key),
      write: (value) => web.window.localStorage.setItem(_key, value),
    );
