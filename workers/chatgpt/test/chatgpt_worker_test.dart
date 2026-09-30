import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'Worker initializes, passively probes, and executes through the CLI',
    () async {
      if (Platform.isWindows) return;
      final root = Directory.current;
      final temp = await Directory.systemTemp.createTemp(
        'chatgpt-worker-test-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final bin = Directory('${temp.path}/bin')..createSync();
      final fakeTool = File('${bin.path}/codex');
      await fakeTool.writeAsString('''#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "codex-cli 1.2.3"
  exit 0
fi
if [ "\$1" = "login" ] && [ "\$2" = "status" ]; then
  exit 0
fi
cat >/dev/null
session_id=fake-session-1
case " \$* " in
  *" resume fake-session-1 "*) session_id=fake-session-2 ;;
esac
cat <<JSON
{"type":"thread.started","thread_id":"\$session_id"}
{"type":"turn.started"}
{"type":"item.completed","item":{"type":"agent_message","text":"OK"}}
{"type":"turn.completed"}
JSON
''');
      await Process.run('chmod', ['700', fakeTool.path]);
      final environment = Map<String, String>.from(Platform.environment)
        ..['PATH'] =
            '${bin.path}${Platform.isWindows ? ';' : ':'}${Platform.environment['PATH'] ?? ''}'
        ..['HOME'] = temp.path
        ..['CONCLAVE_WORKER_STATE_DIR'] = '${temp.path}/state';
      final workerState = Directory('${temp.path}/state')..createSync();
      await File('${workerState.path}/provider-tool-path.json').writeAsString(
        jsonEncode({'path': '/missing/codex', 'version': '0.0.0'}),
      );
      final worker = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/chatgpt_worker.dart'],
        workingDirectory: root.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      final frames = <Map<String, Object?>>[];
      final completed = Completer<void>();
      final outputTask = worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final frame = Map<String, Object?>.from(jsonDecode(line) as Map);
            frames.add(frame);
            if (frame['requestId'] == 'durable-2' && frame['type'] == 'error') {
              if (!completed.isCompleted) completed.complete();
            }
          });
      final errors = StringBuffer();
      final errorTask = worker.stderr
          .transform(utf8.decoder)
          .listen(errors.write);
      void send(Map<String, Object?> frame) =>
          worker.stdin.writeln(jsonEncode(frame));

      send({
        'type': 'initialize.request',
        'protocolVersion': '3.0',
        'requestId': 'init-1',
        'workerTypeId': 'chatgpt',
        'expectedWorkerVersion': '0.1.0',
      });
      send({
        'type': 'probe.request',
        'protocolVersion': '3.0',
        'requestId': 'probe-1',
        'mode': 'passive',
      });
      send({
        'type': 'execute.request',
        'protocolVersion': '3.0',
        'requestId': 'exec-1',
        'assignmentId': 'assignment-1',
        'prompt': 'Say OK',
        'model': null,
        'timeoutMs': 10000,
        'sessionPolicy': 'stateless',
      });
      send({
        'type': 'execute.request',
        'protocolVersion': '3.0',
        'requestId': 'durable-1',
        'assignmentId': 'assignment-2',
        'prompt': 'Continue',
        'model': null,
        'timeoutMs': 10000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'logical-session-1',
      });
      send({
        'type': 'execute.request',
        'protocolVersion': '3.0',
        'requestId': 'durable-2',
        'assignmentId': 'assignment-3',
        'prompt': 'Continue safely',
        'model': null,
        'timeoutMs': 10000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'logical-session-1',
      });
      try {
        await completed.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Assertions below include the observed output; stderr is checked too.
      }
      worker.kill(ProcessSignal.sigterm);
      await worker.exitCode;
      await outputTask.cancel();
      await errorTask.cancel();

      expect(errors.toString(), isEmpty, reason: 'Worker stderr: $errors');
      expect(
        frames.map((frame) => frame['type']),
        containsAll([
          'initialize.result',
          'probe.result',
          'progress',
          'result',
          'error',
        ]),
      );
      final probe = frames.singleWhere(
        (frame) => frame['type'] == 'probe.result',
      );
      expect(probe['ready'], isTrue);
      expect((probe['tool'] as Map)['version'], '1.2.3');
      final result = frames.singleWhere(
        (frame) => frame['requestId'] == 'exec-1' && frame['type'] == 'result',
      );
      expect(result['output'], 'OK');
      final durableResult = frames.singleWhere(
        (frame) =>
            frame['requestId'] == 'durable-1' && frame['type'] == 'result',
      );
      expect(durableResult['output'], 'OK');
      final durableFailure = frames.singleWhere(
        (frame) =>
            frame['requestId'] == 'durable-2' && frame['type'] == 'error',
      );
      expect(durableFailure['type'], 'error');
      expect(durableFailure['code'], 'provider_failure');
      final storedSession =
          jsonDecode(
                await File(
                  '${temp.path}/state/logical-session-1.json',
                ).readAsString(),
              )
              as Map;
      expect(storedSession['providerSessionId'], 'fake-session-1');
    },
  );
}
