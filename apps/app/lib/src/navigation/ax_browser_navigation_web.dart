// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;

import 'ax_browser_navigation_stub.dart';

export 'ax_browser_navigation_stub.dart'
    show AxBrowserNavigation, AxBrowserConnectivity, AxBrowserVisibility;

AxBrowserNavigation createAxBrowserNavigation() => _WebAxBrowserNavigation();

final class _WebAxBrowserNavigation
    implements AxBrowserNavigation, AxBrowserConnectivity, AxBrowserVisibility {
  final _connectivity = StreamController<bool>.broadcast(sync: true);
  final _subscriptions = <StreamSubscription<html.Event>>[];
  _WebAxBrowserNavigation() {
    _subscriptions
        .add(html.window.onOnline.listen((_) => _connectivity.add(true)));
    _subscriptions
        .add(html.window.onOffline.listen((_) => _connectivity.add(false)));
  }
  @override
  bool get visible => html.document.visibilityState == 'visible';
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
    if (returnTo.path == '/login') {
      replace(returnTo);
      return;
    }
    final returnToString = returnTo.toString();
    final uri = Uri(
      path: '/login',
      queryParameters: (returnToString.isEmpty || returnToString == '/')
          ? null
          : {'returnTo': returnToString},
    );
    replace(uri);
  }

  @override
  void startSocialLogin(String provider, Uri returnTo) {
    // Same API base as every other request: in local development the Cloud
    // Worker and this app run on different ports, so a bare '/api' path would
    // hit the app's own dev server. The return target is an absolute URL of
    // this app; Cloud accepts only its own or the configured app origin.
    const configuredApi = String.fromEnvironment('SYNTILA_API_URL');
    final apiBase = configuredApi.isNotEmpty ? configuredApi : '/api';
    final uri = Uri.parse('$apiBase/auth/sign-in/$provider').replace(
      queryParameters: {'returnTo': Uri.base.resolveUri(returnTo).toString()},
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
