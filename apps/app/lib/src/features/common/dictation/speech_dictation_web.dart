import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'speech_dictation.dart';

SpeechDictation createSpeechDictation() => WebSpeechDictation();

class WebSpeechDictation implements SpeechDictation {
  static const _preferenceKey = 'conclave-dictation-language-v1';

  web.SpeechRecognition? _recognition;

  @override
  String get browserLanguage {
    final language = web.window.navigator.language;
    return language.isEmpty ? 'en-US' : language;
  }

  @override
  String? get preferredLanguage {
    try {
      return web.window.localStorage.getItem(_preferenceKey);
    } catch (_) {
      return null;
    }
  }

  @override
  set preferredLanguage(String? value) {
    try {
      if (value == null) {
        web.window.localStorage.removeItem(_preferenceKey);
      } else {
        web.window.localStorage.setItem(_preferenceKey, value);
      }
    } catch (_) {}
  }

  /// Chrome and Safari still expose only the prefixed constructor.
  static JSFunction? get _constructor {
    try {
      final global = globalContext;
      final value =
          global['SpeechRecognition'] ?? global['webkitSpeechRecognition'];
      return value.isA<JSFunction>() ? value as JSFunction : null;
    } catch (_) {
      return null;
    }
  }

  @override
  bool get supported => _constructor != null;

  @override
  void start({
    required String language,
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  }) {
    final constructor = _constructor;
    if (constructor == null) {
      onEnd('not-supported');
      return;
    }
    _recognition?.abort();
    final recognition = constructor.callAsConstructor<web.SpeechRecognition>();
    _recognition = recognition;
    String? error;
    var ended = false;
    recognition
      ..lang = language
      ..continuous = true
      ..interimResults = true
      ..onresult = (web.SpeechRecognitionEvent event) {
        final results = event.results;
        onTranscript(mergeSpeechResults([
          for (var i = 0; i < results.length; i++)
            results.item(i).item(0).transcript,
        ]));
      }.toJS
      ..onerror = (web.SpeechRecognitionErrorEvent event) {
        error = event.error;
      }.toJS
      ..onend = (web.Event _) {
        if (ended) return;
        ended = true;
        if (identical(_recognition, recognition)) _recognition = null;
        onEnd(error);
      }.toJS;
    try {
      recognition.start();
    } catch (_) {
      ended = true;
      _recognition = null;
      onEnd('start-failed');
    }
  }

  @override
  void stop() => _recognition?.stop();
}
