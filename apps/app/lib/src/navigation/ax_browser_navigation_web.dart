// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

import 'ax_browser_navigation_stub.dart';

export 'ax_browser_navigation_stub.dart'
    show AxBrowserNavigation, AxBrowserConnectivity;

AxBrowserNavigation createAxBrowserNavigation() => _WebAxBrowserNavigation();

final class _WebAxBrowserNavigation
    implements AxBrowserNavigation, AxBrowserConnectivity {
  final _connectivity = StreamController<bool>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription<html.Event>>[];
  _WebAxBrowserNavigation() {
    _subscriptions
        .add(html.window.onOnline.listen((_) => _connectivity.add(true)));
    _subscriptions
        .add(html.window.onOffline.listen((_) => _connectivity.add(false)));
  }
  @override
  bool get online => html.window.navigator.onLine ?? true;
  @override
  Stream<bool> get connectivityChanges => _connectivity.stream;
  Uri _current() => Uri.parse(html.window.location.href);

  @override
  Uri get current => _current();

  @override
  Stream<Uri> get changes => html.window.onPopState.map((_) => _current());

  @override
  Stream<void> get lifecycleChanges => html.document.onVisibilityChange
      .where((_) => html.document.visibilityState == 'visible')
      .map((_) {});

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
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_connectivity.close());
  }
}
