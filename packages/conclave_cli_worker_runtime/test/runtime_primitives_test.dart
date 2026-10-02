import 'dart:async';

import 'package:conclave_cli_worker_runtime/conclave_cli_worker_runtime.dart';
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
