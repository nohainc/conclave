import 'speech_dictation_stub.dart'
    if (dart.library.js_interop) 'speech_dictation_web.dart' as platform;

/// Browser speech-to-text for composers. Recognition runs in the browser
/// (some browsers use their vendor's speech service); Conclave only receives
/// the text the user decides to send.
abstract interface class SpeechDictation {
  bool get supported;

  /// Starts listening. [onTranscript] receives the whole session transcript
  /// so far (final and interim words); [onEnd] runs once, with an error code
  /// when recognition failed.
  void start({
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  });

  void stop();
}

SpeechDictation createSpeechDictation() => platform.createSpeechDictation();
