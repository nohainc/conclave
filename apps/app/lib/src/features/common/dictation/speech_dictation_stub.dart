import 'speech_dictation.dart';

SpeechDictation createSpeechDictation() => const _UnsupportedDictation();

class _UnsupportedDictation implements SpeechDictation {
  const _UnsupportedDictation();

  @override
  bool get supported => false;

  @override
  void start({
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  }) =>
      onEnd('not-supported');

  @override
  void stop() {}
}
