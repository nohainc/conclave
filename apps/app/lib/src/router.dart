import 'navigation/studio_navigation.dart';

/// URL-first application router boundary.
///
/// Keeping parsing and serialization behind this type lets the shell and
/// feature modules depend on a stable app-level name while the browser
/// history adapter remains platform-specific.
class AppRouter {
  const AppRouter._();

  static StudioNavigation parse(Uri uri) => StudioNavigation.fromUri(uri);

  static Uri serialize(StudioNavigation route) => route.toUri();
}
