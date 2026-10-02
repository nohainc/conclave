import 'navigation/ax_navigation.dart';

/// URL-first application router boundary.
///
/// Keeping parsing and serialization behind this type lets the shell and
/// feature modules depend on a stable app-level name while the browser
/// history handling remains platform-specific.
class AppRouter {
  const AppRouter._();

  static AxNavigation parse(Uri uri) => AxNavigation.fromUri(uri);

  static Uri serialize(AxNavigation route) => route.toUri();
}
