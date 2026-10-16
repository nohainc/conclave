import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'browser_alerts.dart';

AxBrowserAlerts createAxBrowserAlerts() => WebAxBrowserAlerts();

class WebAxBrowserAlerts implements AxBrowserAlerts {
  static const _preferenceKey = 'conclave-browser-alerts-v1';

  bool get _preferred {
    try {
      return web.window.localStorage.getItem(_preferenceKey) == 'on';
    } catch (_) {
      return false;
    }
  }

  void _setPreferred(bool value) {
    try {
      if (value) {
        web.window.localStorage.setItem(_preferenceKey, 'on');
      } else {
        web.window.localStorage.removeItem(_preferenceKey);
      }
    } catch (_) {}
  }

  @override
  bool get supported {
    try {
      return web.Notification.permission != 'denied';
    } catch (_) {
      return false;
    }
  }

  @override
  bool get enabled {
    try {
      return _preferred && web.Notification.permission == 'granted';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> enable() async {
    try {
      var permission = web.Notification.permission;
      if (permission == 'default') {
        permission = (await web.Notification.requestPermission().toDart).toDart;
      }
      final granted = permission == 'granted';
      _setPreferred(granted);
      return granted;
    } catch (_) {
      return false;
    }
  }

  @override
  void disable() => _setPreferred(false);

  @override
  void show({
    required String title,
    required String body,
    required String tag,
    required void Function() onClick,
  }) {
    if (!enabled) return;
    try {
      final alert = web.Notification(
          title, web.NotificationOptions(body: body, tag: tag));
      alert.onclick = ((web.Event _) {
        web.window.focus();
        alert.close();
        onClick();
      }).toJS;
    } catch (_) {}
  }
}
