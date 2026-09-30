import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'Worker initializes, passively checks local setup, executes and fences resume',
    () async {
      if (Platform.isWindows) return;
      final root = Directory.current;
      final temp = await Directory.systemTemp.createTemp('gemini-worker-test-');
      addTearDown(() => temp.delete(recursive: true));
      final bin = Directory('${temp.path}/bin')..createSync();
      final fakeTool = File('${bin.path}/agy');
      await fakeTool.writeAsString('''#!/bin/sh
if [ "\$1" = "--version" ]; then
  echo "agy 1.2.3"
  exit 0
fi
cat >/dev/null
conversation_id=fake-conversation-1
case " \$* " in
  *" --conversation fake-conversation-1 "*) conversation_id=fake-conversation-2 ;;
esac
cat <<JSON
{"event":"init","conversation_id":"\$conversation_id"}
{"event":"step_update","step_update":{"state":"ACTIVE","step_type":"agent_response"}}
{"event":"result","result":{"conversation_id":"\$conversation_id","status":"SUCCESS","response":"OK"}}
JSON
''');
      await Process.run('chmod', ['700', fakeTool.path]);
      final state = Directory('${temp.path}/state')..createSync();
      await File(
        '${state.path}/provider-tool-path.json',
      ).writeAsString(jsonEncode({'path': '/missing/agy', 'version': '0.0.0'}));
      final environment = Map<String, String>.from(Platform.environment)
        ..['PATH'] = '${bin.path}:${Platform.environment['PATH'] ?? ''}'
        ..['HOME'] = temp.path
        ..['CONCLAVE_WORKER_STATE_DIR'] = state.path;
      final worker = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/gemini_worker.dart'],
        workingDirectory: root.path,
        environment: environment,
        includeParentEnvironment: false,
      );
      final frames = <Map<String, Object?>>[];
      final done = Completer<void>();
      final outputTask = worker.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            final frame = Map<String, Object?>.from(jsonDecode(line) as Map);
            frames.add(frame);
            if (frame['type'] == 'error' && frame['requestId'] == 'durable-2') {
              if (!done.isCompleted) done.complete();
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
        'workerTypeId': 'gemini',
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
        'requestId': 'durable-1',
        'assignmentId': 'assignment-1',
        'prompt': 'Say OK',
        'model': null,
        'timeoutMs': 10000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'logical-session-1',
      });
      send({
        'type': 'execute.request',
        'protocolVersion': '3.0',
        'requestId': 'durable-2',
        'assignmentId': 'assignment-2',
        'prompt': 'Continue safely',
        'model': null,
        'timeoutMs': 10000,
        'sessionPolicy': 'durable_session',
        'sessionKey': 'logical-session-1',
      });
      try {
        await done.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        // Assertions below show the frames that arrived before the deadline.
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
      expect(
        (probe['checks'] as List).any(
          (check) => (check as Map)['status'] == 'warning',
        ),
        isTrue,
      );
      final success = frames.singleWhere(
        (frame) =>
            frame['requestId'] == 'durable-1' && frame['type'] == 'result',
      );
      expect(success['output'], 'OK');
      final mismatch = frames.singleWhere(
        (frame) =>
            frame['requestId'] == 'durable-2' && frame['type'] == 'error',
      );
      expect(mismatch['code'], 'provider_failure');
      final stored =
          jsonDecode(
                await File(
                  '${state.path}/logical-session-1.json',
                ).readAsString(),
              )
              as Map;
      expect(stored['providerSessionId'], 'fake-conversation-1');
    },
  );
}
