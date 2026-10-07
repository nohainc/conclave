import 'dart:convert';
import 'dart:io';

const _livePrompt = 'Reply with exactly the word OK. Do not use tools.';

Future<void> main(List<String> arguments) async {
  if (arguments.length == 1 && arguments.single == '--version') {
    stdout.writeln('codex-cli 1.2.3');
    return;
  }
  if (arguments.length == 2 &&
      arguments[0] == 'login' &&
      arguments[1] == 'status') {
    return;
  }

  final prompt = await stdin.transform(utf8.decoder).join();
  final isLive = prompt == _livePrompt;
  final isDurable =
      prompt == 'Start durable' ||
      prompt == 'Continue durable' ||
      prompt == 'Continue safely';
  final isResume = arguments.contains('resume');
  final isMismatch = prompt == 'Continue safely';
  final isPermissionFailure = prompt == 'Permission failure';
  final isProviderEventFailure = prompt == 'Provider event failure';
  final expectedEphemeral = !isDurable;
  final modelCorrect = prompt == 'Say OK'
      ? (_hasPair(arguments, '--model', 'gpt-fixture') ||
            _hasPair(arguments, '--model', 'gpt-test'))
      : !arguments.contains('--model');
  final resumeCorrect =
      isResume ==
          (prompt == 'Continue durable' || prompt == 'Continue safely') &&
      (!isResume || _hasPair(arguments, 'resume', 'fake-session-1'));
  final argumentsCorrect =
      _hasPair(arguments, '--ask-for-approval', 'never') &&
      _hasPair(arguments, '--sandbox', 'workspace-write') &&
      arguments.contains('--json') &&
      _hasPair(arguments, '--color', 'never') &&
      arguments.contains('--skip-git-repo-check') &&
      _hasPair(arguments, '--cd', Directory.current.path) &&
      arguments.isNotEmpty &&
      arguments.last == '-' &&
      arguments.contains('--ephemeral') == expectedEphemeral &&
      modelCorrect &&
      resumeCorrect &&
      (!isDurable || !arguments.contains('--ephemeral'));
  final environmentCorrect =
      Platform.environment['NO_COLOR'] == '1' &&
      Platform.environment['OPENAI_API_KEY'] == 'codex-fixture-key' &&
      Platform.environment['CODEX_HOME']?.isNotEmpty == true;
  if (!argumentsCorrect || !environmentCorrect) {
    stderr.writeln(
      'fixture arguments or environment did not match: '
      'prompt=$prompt args=$arguments argsOk=$argumentsCorrect envOk=$environmentCorrect',
    );
    exitCode = 2;
    return;
  }
  if (isPermissionFailure) {
    stderr.writeln('permission denied by sandbox');
    exitCode = 1;
    return;
  }

  final fixtureName = isLive
      ? 'live-probe'
      : isMismatch
      ? 'session-mismatch'
      : isProviderEventFailure
      ? 'permission-error'
      : 'success';
  final fixture = File(
    'packages/tool-profile/test/fixtures/codex-events/$fixtureName.jsonl',
  );
  stdout.write(await fixture.readAsString());
}

bool _hasPair(List<String> arguments, String key, String value) {
  final index = arguments.indexOf(key);
  return index >= 0 &&
      index + 1 < arguments.length &&
      arguments[index + 1] == value;
}
