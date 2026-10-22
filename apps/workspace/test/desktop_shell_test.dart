import 'dart:io';

import 'package:conclave_workspace/desktop_shell.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('test.conclave.workspace/desktop');

class _Recorder {
  final calls = <(String, List<String>)>[];
  final logs = <String>[];
  ProcessResult result = ProcessResult(0, 0, '', '');
  Object? throwOnRun;

  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add((executable, arguments));
    if (throwOnRun != null) throw throwOnRun!;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Recorder recorder;

  DesktopShell shell(String os) => DesktopShell(
        channel: _channel,
        runProcess: recorder.run,
        operatingSystem: os,
        log: recorder.logs.add,
      );

  void nativeHandler(Future<Object?>? Function(MethodCall call)? handler) =>
      messenger.setMockMethodCallHandler(_channel, handler);

  setUp(() => recorder = _Recorder());
  tearDown(() => nativeHandler(null));

  test('openPath uses the native channel when available', () async {
    final methods = <String>[];
    nativeHandler((call) async {
      methods.add(call.method);
      return null;
    });

    await shell('macos').openPath('/tmp/work');

    expect(methods, ['openPath']);
    expect(recorder.calls, isEmpty);
    expect(recorder.logs, isEmpty);
  });

  test('openPath falls back per platform and logs the native failure',
      () async {
    for (final (os, executable) in [
      ('macos', 'open'),
      ('linux', 'xdg-open'),
      ('windows', 'explorer'),
    ]) {
      recorder = _Recorder();
      await shell(os).openPath('/tmp/work');
      final (ran, arguments) = recorder.calls.single;
      expect(ran, executable, reason: os);
      expect(arguments, ['/tmp/work'], reason: os);
      expect(recorder.logs.single, contains('openPath'), reason: os);
    }
  });

  test('fallback process failures are logged instead of thrown', () async {
    recorder.throwOnRun = const ProcessException('xdg-open', []);

    await shell('linux').openPath('/tmp/work');

    expect(recorder.logs.last, contains('Could not open /tmp/work'));
  });

  test('openAX falls back on Windows too', () async {
    await shell('windows').openAX();

    expect(recorder.calls.single.$1, 'explorer');
  });

  test('chooseDirectory prefers a non-empty native selection', () async {
    nativeHandler((call) async => '  /picked  ');

    expect(await shell('linux').chooseDirectory(), '/picked');
    expect(recorder.calls, isEmpty);
  });

  test('chooseDirectory falls back and treats non-zero exit as cancel',
      () async {
    recorder.result = ProcessResult(0, 0, '/chosen\n', '');
    expect(await shell('linux').chooseDirectory(), '/chosen');
    expect(recorder.calls.single.$1, 'zenity');

    recorder = _Recorder()..result = ProcessResult(0, 1, '', '');
    expect(await shell('linux').chooseDirectory(), isNull);
  });

  test('macOS picker escapes the initial path for AppleScript', () {
    final dir = Directory.systemTemp.createTempSync('quote"dir');
    addTearDown(() => dir.deleteSync());

    final command =
        DesktopShell.directoryPickerCommand('macos', initialPath: dir.path)!;

    expect(command.$1, 'osascript');
    expect(command.$2.last, contains(r'quote\"dir'));
    expect(DesktopShell.appleScriptEscape(r'a\b"c'), r'a\\b\"c');
  });

  test('unsupported platforms have no picker fallback', () {
    expect(DesktopShell.directoryPickerCommand('fuchsia'), isNull);
  });
}
