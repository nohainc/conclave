// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

import 'ax_browser_navigation_stub.dart';

export 'ax_browser_navigation_stub.dart' show AxBrowserNavigation;

AxBrowserNavigation createAxBrowserNavigation() => _WebAxBrowserNavigation();

final class _WebAxBrowserNavigation implements AxBrowserNavigation {
  Uri _current() => Uri.parse(html.window.location.href);

  @override
  Uri get current => _current();

  @override
  Stream<Uri> get changes => html.window.onPopState.map((_) => _current());

  @override
  Stream<void> get lifecycleChanges =>
      html.document.onVisibilityChange.map((_) {});

  @override
  void push(Uri uri) => html.window.history.pushState(null, '', uri.toString());

  @override
  void replace(Uri uri) =>
      html.window.history.replaceState(null, '', uri.toString());

  @override
  void replaceWithLogin(Uri returnTo) {
    final uri = Uri(
      path: '/login',
      queryParameters: {'returnTo': returnTo.toString()},
    );
    replace(uri);
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {
    final uri = Uri(
      path: '/api/auth/sign-in/$provider',
      queryParameters: {'returnTo': returnTo.toString()},
    );
    html.window.location.assign(uri.toString());
  }

  @override
  void openExternal(Uri uri) => html.window.open(uri.toString(), '_blank');

  @override
  bool closeCurrentWindow() {
    html.window.close();
    return html.window.closed ?? false;
  }

  @override
  void dispose() {}
}
