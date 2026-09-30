import 'dart:async';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
import 'dart:convert';
import 'package:test/test.dart';

void main() {
  test(
    'environment construction includes only explicitly allowed parent keys',
    () {
      final environment =
          const CliEnvironmentBuilder(allowedParentKeys: {'PATH'}).build(
            parentEnvironment: const {'PATH': '/bin', 'API_KEY': 'secret'},
            values: const {'LANG': 'C.UTF-8'},
          );
      expect(environment, {'PATH': '/bin', 'LANG': 'C.UTF-8'});
    },
  );

  test('diagnostics redact secret fields before bounding text', () {
    final captured = const WorkerDiagnosticCollector(
      maxCharacters: 80,
    ).capture('{"access_token":"secret value","note":"safe"}');
    expect(captured, contains('[REDACTED]'));
    expect(captured, isNot(contains('secret value')));
    expect(captured.length, lessThanOrEqualTo(80));
  });

  test('Worker logger emits safe event codes and omits input fields', () {
    String? captured;
    WorkerLogger(writeLine: (line) => captured = line).log(
      'info',
      'assignment.started',
      context: const {
        'assignmentId': 'assignment-1',
        'prompt': 'private prompt text',
        'fileContents': 'private file text',
        'apiKey': 'secret-key-value',
      },
    );

    final event = jsonDecode(captured!) as Map<String, dynamic>;
    expect(event['event'], 'assignment.started');
    expect(event['context']['assignmentId'], 'assignment-1');
    expect(captured, isNot(contains('private prompt text')));
    expect(captured, isNot(contains('private file text')));
    expect(captured, isNot(contains('secret-key-value')));
  });

  test('deadline cancellation invokes the process cleanup hook', () async {
    var cleaned = false;
    final deadline = WorkerDeadlineController(
      const Duration(seconds: 1),
      onCancel: () => cleaned = true,
    );
    final pending = deadline.run<void>(() => Completer<void>().future);
    deadline.cancel();
    await expectLater(pending, throwsA(isA<WorkerCancelledException>()));
    expect(cleaned, isTrue);
  });
}
