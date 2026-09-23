// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:js_interop';

import 'passkey_browser_stub.dart';

@JS('conclavePasskey.register')
external JSPromise<JSAny?> _register(JSString baseUrl, JSString name);

@JS('conclavePasskey.signIn')
external JSPromise<JSAny?> _signIn(JSString baseUrl);

final class _WebStudioPasskeyBrowser implements StudioPasskeyBrowser {
  @override
  Future<void> register(String baseUrl, String name) =>
      _register(baseUrl.toJS, name.toJS).toDart;

  @override
  Future<void> signIn(String baseUrl) => _signIn(baseUrl.toJS).toDart;
}

StudioPasskeyBrowser createStudioPasskeyBrowser() => _WebStudioPasskeyBrowser();
