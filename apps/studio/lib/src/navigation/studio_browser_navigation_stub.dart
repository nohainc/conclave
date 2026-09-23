import 'dart:async';

abstract interface class StudioBrowserNavigation {
  Uri get current;
  Stream<Uri> get changes;
  void push(Uri uri);
  void replace(Uri uri);
  void replaceWithLogin(Uri returnTo);
  void dispose();
}

StudioBrowserNavigation createStudioBrowserNavigation() =>
    _StubStudioBrowserNavigation();

final class _StubStudioBrowserNavigation implements StudioBrowserNavigation {
  @override
  Uri get current => Uri.base;

  @override
  Stream<Uri> get changes => const Stream<Uri>.empty();

  @override
  void push(Uri uri) {}

  @override
  void replace(Uri uri) {}

  @override
  void replaceWithLogin(Uri returnTo) {}

  @override
  void dispose() {}
}
