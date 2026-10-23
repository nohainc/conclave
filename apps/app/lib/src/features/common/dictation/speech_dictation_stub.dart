import 'speech_dictation.dart';

SpeechDictation createSpeechDictation() => _UnsupportedDictation();

class _UnsupportedDictation implements SpeechDictation {
  @override
  bool get supported => false;

  @override
  String get browserLanguage => 'en-US';

  @override
  String? preferredLanguage;

  @override
  void start({
    required String language,
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  }) =>
      onEnd('not-supported');

  @override
  void stop() {}
}
