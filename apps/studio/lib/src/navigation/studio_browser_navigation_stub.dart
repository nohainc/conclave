import 'dart:async';

abstract interface class StudioBrowserNavigation {
  Uri get current;
  Stream<Uri> get changes;
  Stream<void> get lifecycleChanges;
  void push(Uri uri);
  void replace(Uri uri);
  void replaceWithLogin(Uri returnTo);
  void startSocialLogin(String provider, Uri returnTo);
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
  Stream<void> get lifecycleChanges => const Stream<void>.empty();

  @override
  void push(Uri uri) {}

  @override
  void replace(Uri uri) {}

  @override
  void replaceWithLogin(Uri returnTo) {}

  @override
  void startSocialLogin(String provider, Uri returnTo) {}

  @override
  void dispose() {}
}
