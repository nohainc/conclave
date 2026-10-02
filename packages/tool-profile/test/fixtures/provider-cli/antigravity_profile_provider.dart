import 'dart:convert';
import 'dart:io';

const _livePrompt = 'Reply with exactly the word OK. Do not use tools.';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('agy 1.2.3');
    return;
  }

  final input = await stdin.transform(utf8.decoder).join();
  final Object? decodedInput;
  try {
    decodedInput = jsonDecode(input);
  } on FormatException {
    stderr.writeln('fixture expected stream-json user input');
    exitCode = 2;
    return;
  }
  if (decodedInput is! Map ||
      decodedInput['event'] != 'user' ||
      decodedInput['message'] is! Map ||
      (decodedInput['message'] as Map)['content'] is! String ||
      !input.endsWith('\n')) {
    stderr.writeln('fixture received invalid stream-json input');
    exitCode = 2;
    return;
  }
  final prompt = (decodedInput['message'] as Map)['content'] as String;
  final isLive = prompt == _livePrompt;
  final isResume = arguments.contains('--conversation');
  final isMismatch = prompt == 'Continue safely';
  final isSessionConflict = prompt == 'Conflicting session';
  final isAuthFailure = prompt == 'Provider auth failure';
  final isPermissionFailure = prompt == 'Provider permission failure';
  final isMissingTerminal = prompt == 'Missing terminal';
  final timeout = isLive ? '29s' : '9s';
  final expectedResume =
      prompt == 'Continue durable' || prompt == 'Continue safely';
  final modelCorrect = prompt == 'Say OK'
      ? _hasPair(arguments, '--model', 'gemini-fixture')
      : !arguments.contains('--model');
  final argumentsCorrect =
      _hasPair(arguments, '--input-format', 'stream-json') &&
      _hasPair(arguments, '--output-format', 'stream-json') &&
      arguments.contains('--sandbox') &&
      _hasPair(arguments, '--print-timeout', timeout) &&
      isResume == expectedResume &&
      (!isResume ||
          _hasPair(arguments, '--conversation', 'fixture-conversation-1')) &&
      modelCorrect;
  final environmentCorrect =
      Platform.environment['NO_COLOR'] == null &&
      Platform.environment['AGY_ADC_AUTH'] == 'agy-fixture-adc' &&
      Platform.environment['GEMINI_API_KEY'] == 'gemini-fixture-key' &&
      Platform.environment['GOOGLE_API_KEY'] == 'google-fixture-key' &&
      Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'] ==
          '/fixture/credentials.json' &&
      Platform.environment['GOOGLE_CLOUD_PROJECT'] == 'fixture-project' &&
      Platform.environment['GOOGLE_CLOUD_LOCATION'] == 'fixture-region' &&
      Platform.environment['GOOGLE_GEMINI_BASE_URL'] ==
          'https://fixture.invalid' &&
      Platform.environment['USERPROFILE']?.isNotEmpty == true &&
      Platform.environment['ProgramFiles']?.isNotEmpty == true &&
      Platform.environment['TMP']?.isNotEmpty == true &&
      Platform.environment['TEMP']?.isNotEmpty == true &&
      Platform.environment['TMPDIR']?.isNotEmpty == true &&
      Platform.environment['LANG']?.isNotEmpty == true &&
      Platform.environment['LC_ALL']?.isNotEmpty == true &&
      Platform.environment['SSL_CERT_FILE']?.isNotEmpty == true &&
      Platform.environment['SSL_CERT_DIR']?.isNotEmpty == true;
  if (!argumentsCorrect || !environmentCorrect) {
    stderr.writeln(
      'fixture arguments/environment mismatch: prompt=$prompt '
      'args=$arguments argsOk=$argumentsCorrect envOk=$environmentCorrect',
    );
    exitCode = 2;
    return;
  }

  final fixtureName = isLive
      ? 'live-probe'
      : isMismatch
      ? 'session-mismatch'
      : isSessionConflict
      ? 'session-conflict'
      : isAuthFailure
      ? 'auth-error'
      : isPermissionFailure
      ? 'permission-error'
      : prompt == 'Continue after incompatible upgrade'
      ? 'fresh-session'
      : isMissingTerminal
      ? 'missing-terminal'
      : 'success';
  final fixture = File(
    'packages/tool-profile/test/fixtures/antigravity-events/$fixtureName.jsonl',
  );
  final content = await fixture.readAsString();
  // The success corpus echoes the initial conversation ID on resumed turns so
  // the Engine can verify the stored identity.
  stdout.write(content);
}

bool _hasPair(List<String> arguments, String key, String value) {
  final index = arguments.indexOf(key);
  return index >= 0 &&
      index + 1 < arguments.length &&
      arguments[index + 1] == value;
}
