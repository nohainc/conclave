import 'theme_preference.dart';

ThemePreference createThemePreference() {
  String? value;
  return ThemePreference(read: () => value, write: (next) => value = next);
}
