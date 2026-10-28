import 'speech_dictation_stub.dart'
    if (dart.library.js_interop) 'speech_dictation_web.dart' as platform;

/// Browser speech-to-text for composers. Recognition runs in the browser
/// (some browsers use their vendor's speech service); Syntila only receives
/// the text the user decides to send.
abstract interface class SpeechDictation {
  bool get supported;

  /// BCP 47 tag of the browser's own language, used when nothing is chosen.
  String get browserLanguage;

  /// Language the user picked on this device, or null for the browser's.
  String? get preferredLanguage;
  set preferredLanguage(String? value);

  /// Starts listening in [language]. [onTranscript] receives the whole
  /// session transcript so far (final and interim words); [onEnd] runs
  /// once, with an error code when recognition failed.
  void start({
    required String language,
    required void Function(String transcript) onTranscript,
    required void Function(String? error) onEnd,
  });

  void stop();
}

/// Languages offered in the mic menu, as (BCP 47 tag, native name).
const dictationLanguages = [
  ('en-US', 'English (US)'),
  ('en-GB', 'English (UK)'),
  ('uk-UA', 'Українська'),
  ('pl-PL', 'Polski'),
  ('de-DE', 'Deutsch'),
  ('fr-FR', 'Français'),
  ('es-ES', 'Español'),
  ('it-IT', 'Italiano'),
  ('pt-BR', 'Português (Brasil)'),
  ('nl-NL', 'Nederlands'),
  ('cs-CZ', 'Čeština'),
  ('tr-TR', 'Türkçe'),
  ('ru-RU', 'Русский'),
  ('ja-JP', '日本語'),
  ('ko-KR', '한국어'),
  ('zh-CN', '中文 (简体)'),
  ('hi-IN', 'हिन्दी'),
  ('ar-SA', 'العربية'),
];

SpeechDictation createSpeechDictation() => platform.createSpeechDictation();

/// Joins a recognition session's result segments into one transcript.
///
/// Desktop browsers report each result as a new segment, but Chrome on
/// Android repeats the whole utterance so far in every result. A segment
/// that already contains the transcript replaces it, and a segment the
/// transcript already ends with is skipped, so text is never duplicated.
String mergeSpeechResults(Iterable<String> segments) {
  var merged = '';
  for (final segment in segments) {
    final current = merged.trim().toLowerCase();
    final next = segment.trim().toLowerCase();
    if (next.isEmpty) continue;
    if (current.isNotEmpty && next.startsWith(current)) {
      merged = segment;
    } else if (current.endsWith(next)) {
      continue;
    } else {
      merged += segment;
    }
  }
  return merged.trim();
}
